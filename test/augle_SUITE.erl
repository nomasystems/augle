%%% ---------------------------------------------------------------------------
%%% @doc
%%% @end
%%% ---------------------------------------------------------------------------
-module(augle_SUITE).

-compile(export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

-define(EMPTY_CONFIG_DIR, "a_directory_that_does_not_exist").

all() ->
    [os_var_default,
     signed_jwt_is_well_formed,
     config_path_default,
     metadata_default,
     error_response_is_returned,
     unparseable_body_is_returned_as_error,
     token_cache_refresh,
     proactive_refresh_keeps_the_cache_warm,
     concurrent_misses_fetch_once,
     short_lived_token_does_not_crash,
     broken_credentials_do_not_take_down_the_store].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(nhttp),
    {ok, Owner, Port} = augle_test_google:start(),
    BaseUrl = iolist_to_binary(io_lib:format("http://127.0.0.1:~b", [Port])),

    {ok, _} = application:ensure_all_started(augle),
    %% point every endpoint augle knows about at the stand-in server
    ok = application:set_env(augle, auth_host, BaseUrl),
    ok = application:set_env(augle, auth_path, <<"/oauth2/v4/token">>),
    ok = application:set_env(augle, metadata_host, BaseUrl),
    ok = application:set_env(augle, token_endpoint, <<BaseUrl/binary, "/o/oauth2/token">>),

    [{server, Owner}, {base_url, BaseUrl} | Config].

end_per_suite(Config) ->
    ok = application:stop(augle),
    ok = augle_test_google:stop(?config(server, Config)),
    ok = application:stop(nhttp),
    ok.

init_per_testcase(_, Config) ->
    ok = augle_test_google:reset(),
    ok = augle_token_store:flush(),
    os:unsetenv("GOOGLE_APPLICATION_CREDENTIALS"),
    os:putenv("CLOUDSDK_CONFIG", ?EMPTY_CONFIG_DIR),
    Config.

end_per_testcase(_, _Config) ->
    ok = augle_test_google:reset(),
    ok = application:unset_env(augle, expiry_margin),
    ok = application:unset_env(augle, refresh_margin),
    os:unsetenv("GOOGLE_APPLICATION_CREDENTIALS"),
    os:unsetenv("CLOUDSDK_CONFIG"),
    ok.

%%%-----------------------------------------------------------------------------
%%% TEST CASES
%%%-----------------------------------------------------------------------------

%% GOOGLE_APPLICATION_CREDENTIALS points at a service account file, so we sign a
%% JWT and exchange it at auth_host ++ auth_path.
os_var_default(Config) ->
    service_account_creds(Config),
    augle_test_google:respond_with(token(<<"abc123">>, 3600, <<"service_account">>)),

    ?assertMatch({ok, #{access_token := <<"abc123">>,
                        expires_in := 3600,
                        token_type := <<"service_account">>}},
                 augle:app_default_credentials()),

    [Request] = augle_test_google:requests(),
    ?assertMatch(#{method := post, path := <<"/oauth2/v4/token">>}, Request),
    ?assertEqual(<<"application/x-www-form-urlencoded">>,
                 nhttp:header(<<"content-type">>, Request)).

%% The assertion we send is a real RS256 JWT, base64url encoded and unpadded.
signed_jwt_is_well_formed(Config) ->
    service_account_creds(Config),
    augle_test_google:respond_with(token(<<"abc123">>, 3600, <<"service_account">>)),
    {ok, _} = augle:app_default_credentials(),

    [#{body := Body}] = augle_test_google:requests(),
    Params = uri_string:dissect_query(iolist_to_binary(Body)),
    ?assertEqual(<<"urn:ietf:params:oauth:grant-type:jwt-bearer">>,
                 proplists:get_value(<<"grant_type">>, Params)),

    Assertion = proplists:get_value(<<"assertion">>, Params),
    [Header, ClaimSet, Signature] = binary:split(Assertion, <<".">>, [global]),

    %% base64url alphabet only, and no padding left behind
    [?assertEqual(nomatch, binary:match(Part, [<<"+">>, <<"/">>, <<"=">>]))
     || Part <- [Header, ClaimSet, Signature]],

    ?assertEqual(#{<<"alg">> => <<"RS256">>, <<"typ">> => <<"JWT">>},
                 json:decode(base64:decode(Header, #{mode => urlsafe, padding => false}))),

    Claims = json:decode(base64:decode(ClaimSet, #{mode => urlsafe, padding => false})),
    ?assertMatch(#{<<"iss">> := <<"fakeaccount@fake.iam.gserviceaccount.com">>,
                   <<"aud">> := _,
                   <<"exp">> := _,
                   <<"iat">> := _}, Claims),
    #{<<"exp">> := Exp, <<"iat">> := Iat} = Claims,
    ?assertEqual(3600, Exp - Iat).

%% No env var, but CLOUDSDK_CONFIG holds an application_default_credentials.json,
%% so we take the refresh token grant against token_endpoint.
config_path_default(Config) ->
    os:putenv("CLOUDSDK_CONFIG", ?config(data_dir, Config)),
    augle_test_google:respond_with(token(<<"def123">>, 3600, <<"service_account">>)),

    ?assertMatch({ok, #{access_token := <<"def123">>,
                        expires_in := 3600,
                        token_type := <<"service_account">>}},
                 augle:app_default_credentials()),

    [#{method := post, path := Path, body := Body}] = augle_test_google:requests(),
    ?assertEqual(<<"/o/oauth2/token">>, Path),
    Params = uri_string:dissect_query(iolist_to_binary(Body)),
    ?assertEqual(<<"refresh_token">>, proplists:get_value(<<"grant_type">>, Params)),
    ?assertEqual(<<"mmm, refreshing">>, proplists:get_value(<<"refresh_token">>, Params)).

%% Nothing on disk, so we fall through to the instance metadata server.
metadata_default(_Config) ->
    augle_test_google:respond_with(token(<<"abc321">>, 3600, <<"Bearer">>)),

    ?assertMatch({ok, #{access_token := <<"abc321">>,
                        expires_in := 3600,
                        token_type := <<"Bearer">>}},
                 augle:app_default_credentials()),

    [Request] = augle_test_google:requests(),
    ?assertMatch(#{method := get,
                   path := <<"/computeMetadata/v1/instance/service-accounts/default/token">>},
                 Request),
    ?assertEqual(<<"Google">>, nhttp:header(<<"metadata-flavor">>, Request)).

%% A non-200 comes back as {error, _}. Used to crash with a badmatch on the
%% refresh grant path, where the response body was matched against the request
%% body still bound in scope.
error_response_is_returned(Config) ->
    os:putenv("CLOUDSDK_CONFIG", ?config(data_dir, Config)),
    augle_test_google:respond_with(
      {400, json:encode(#{error => <<"invalid_grant">>,
                          error_description => <<"Token has been expired or revoked.">>})}),

    ?assertEqual({error, #{<<"error">> => <<"invalid_grant">>,
                           <<"error_description">> => <<"Token has been expired or revoked.">>}},
                 augle:app_default_credentials()).

%% Something other than Google answered (a proxy, a captive portal). Report it
%% rather than crash the caller.
unparseable_body_is_returned_as_error(_Config) ->
    augle_test_google:respond_with({200, <<"<html>502 Bad Gateway</html>">>}),
    ?assertMatch({error, {invalid_json, _}}, augle:app_default_credentials()).

%% Nothing scheduled a refresh (expires_in sits under refresh_margin), so this
%% is the fallback: the token ages past its serve-until and the next caller
%% fetches a fresh one.
token_cache_refresh(_Config) ->
    augle_test_google:respond_with(fun(_Req) -> unique_token() end),

    ?assertEqual(notfound, augle_token_store:lookup(default)),

    {ok, #{access_token := Token1}} = augle:creds_from(default),
    %% still inside its life, so this one is served from the cache
    ?assertMatch({ok, #{access_token := Token1}}, augle:creds_from(default)),
    ?assertEqual(1, length(augle_test_google:requests())),

    %% expires_in is 11 and the margin is 10, so a second later it is spent
    timer:sleep(1500),
    ?assertEqual(notfound, augle_token_store:lookup(default)),

    {ok, #{access_token := Token2}} = augle:creds_from(default),
    ?assertNotEqual(Token1, Token2),
    ?assertEqual(2, length(augle_test_google:requests())).

%% Under steady load the refresh lands before the token stops being served, so
%% a reader never sees a miss and never waits on a token exchange.
proactive_refresh_keeps_the_cache_warm(_Config) ->
    ok = application:set_env(augle, expiry_margin, 1),
    ok = application:set_env(augle, refresh_margin, 3),
    %% 5s tokens: served until 4s, refreshed in the background at 2s
    augle_test_google:respond_with(fun(_Req) -> unique_token(5) end),

    {ok, #{access_token := Token1}} = augle:creds_from(default),
    ?assertEqual(1, length(augle_test_google:requests())),

    timer:sleep(2500),

    %% a bare ETS read, so a new token here can only have come from the
    %% background refresh, and the old one was still being served throughout
    Token2 = maps:get(access_token, augle_token_store:lookup(default)),
    ?assertNotEqual(Token1, Token2),
    ?assertEqual(2, length(augle_test_google:requests())).

%% A burst of callers arriving on a cold cache costs one request, not one each.
concurrent_misses_fetch_once(_Config) ->
    augle_test_google:respond_with(fun(_Req) -> unique_token() end),
    CredsFrom = {metadata, <<"herd">>},

    Parent = self(),
    Pids = [spawn(fun() -> Parent ! {self(), augle:creds_from(CredsFrom)} end)
            || _ <- lists:seq(1, 20)],
    Results = [receive {Pid, Result} -> Result after 5000 -> timeout end || Pid <- Pids],

    ?assertEqual(1, length(lists:usort(Results))),
    ?assertMatch([{ok, #{access_token := _}}], lists:usort(Results)),
    ?assertEqual(1, length(augle_test_google:requests())).

%% expires_in below the expiry margin used to crash the store: the refresh timer
%% was scheduled at expires_in - 10, and start_timer/3 rejects a negative time.
short_lived_token_does_not_crash(_Config) ->
    Store = whereis(augle_token_store),
    augle_test_google:respond_with(token(<<"short">>, 5, <<"Bearer">>)),

    ?assertMatch({ok, #{access_token := <<"short">>}}, augle:creds_from(default)),
    %% never worth caching, but the store is still standing
    ?assertEqual(notfound, augle_token_store:lookup(default)),
    ?assertMatch({ok, #{access_token := <<"short">>}}, augle:creds_from(default)),
    ?assertEqual(Store, whereis(augle_token_store)).

%% A credential that blows up on the way out is the caller's problem, not the
%% whole cache's: fetching runs in the shared server process now.
broken_credentials_do_not_take_down_the_store(_Config) ->
    Store = whereis(augle_token_store),

    ?assertMatch({error, {credentials_error, error, {badmatch, {error, enoent}}, _}},
                 augle:creds_from({file, "/does/not/exist.json"})),

    ?assertEqual(Store, whereis(augle_token_store)),
    augle_test_google:respond_with(token(<<"fine">>, 3600, <<"Bearer">>)),
    ?assertMatch({ok, #{access_token := <<"fine">>}}, augle:creds_from(default)).

%%%-----------------------------------------------------------------------------
%%% HELPERS
%%%-----------------------------------------------------------------------------
service_account_creds(Config) ->
    Path = filename:join(?config(data_dir, Config), "fake_service_account.json"),
    os:putenv("GOOGLE_APPLICATION_CREDENTIALS", Path).

token(AccessToken, ExpiresIn, TokenType) ->
    #{access_token => AccessToken,
      expires_in => ExpiresIn,
      token_type => TokenType}.

unique_token() ->
    unique_token(11).

unique_token(ExpiresIn) ->
    Token = integer_to_binary(erlang:unique_integer([positive])),
    #{status => 200,
      headers => [{<<"content-type">>, <<"application/json">>}],
      body => json:encode(token(Token, ExpiresIn, <<"Bearer">>))}.
