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
     token_cache_refresh].

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
    os:unsetenv("GOOGLE_APPLICATION_CREDENTIALS"),
    os:putenv("CLOUDSDK_CONFIG", ?EMPTY_CONFIG_DIR),
    Config.

end_per_testcase(_, _Config) ->
    ok = augle_test_google:reset(),
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

%% The cache hands back a token until 10 seconds before it expires, then the
%% store refreshes it on its own.
token_cache_refresh(_Config) ->
    augle_test_google:respond_with(fun(_Req) -> unique_token() end),

    ?assertEqual(notfound, augle_token_store:get(default)),

    {ok, #{access_token := Token1}} = augle:creds_from(default),
    timer:sleep(1500),

    #{access_token := Token2} = augle_token_store:get(default),
    ?assertNotEqual(Token1, Token2),

    timer:sleep(1500),
    {ok, #{access_token := Token3}} = augle:creds_from(default),
    ?assertNotEqual(Token1, Token3),
    ?assertNotEqual(Token2, Token3).

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

%% expires_in of 11 makes the store schedule its refresh one second out
unique_token() ->
    Token = integer_to_binary(erlang:unique_integer([positive])),
    #{status => 200,
      headers => [{<<"content-type">>, <<"application/json">>}],
      body => json:encode(token(Token, 11, <<"Bearer">>))}.
