%%%-------------------------------------------------------------------
%%% @author Tristan Sloughter <t@crashfast.com>
%%% @copyright (C) 2017, Tristan Sloughter
%%% @doc
%%%
%%% @end
%%% Created : 16 Sep 2017 by Tristan Sloughter <t@crashfast.com>
%%%-------------------------------------------------------------------
-module(augle_gcloud_sdk).

-export([app_default_credentials/2,
         creds_from_file/2,
         creds_from_json/2,
         metadata_fetch_token/1,
         get_config_path/0]).

-define(META_HEADERS, [{<<"metadata-flavor">>, <<"Google">>}]).

-define(CREDENTIALS_FILENAME, <<"application_default_credentials.json">>).

-define(APP_CREDENTIALS, "GOOGLE_APPLICATION_CREDENTIALS").
-define(CONFIG_DIR, "CLOUDSDK_CONFIG").

-define(URLENCODED_CONTENT_TYPE, <<"application/x-www-form-urlencoded">>).
-define(JWT_GRANT_TYPE, <<"urn:ietf:params:oauth:grant-type:jwt-bearer">>).
-define(REFRESH_GRANT_TYPE, <<"refresh_token">>).

%%%-----------------------------------------------------------------------------
%%% FINDING CREDENTIALS
%%%-----------------------------------------------------------------------------
app_default_credentials(ServiceAccount, Scopes) ->
    case os:getenv(?APP_CREDENTIALS) of
        false ->
            default_path_or_metadata(ServiceAccount);
        Path ->
            creds_from_file(Path, Scopes)
    end.

creds_from_file(Path, Scopes) when is_list(Scopes) ->
    CombinedScopes = iolist_to_binary(lists:join($,, Scopes)),
    creds_from_file(Path, CombinedScopes);
creds_from_file(Path, Scopes) ->
    {ok, File} = file:read_file(Path),
    creds_from_map(json:decode(File), Scopes).

creds_from_json(JsonCreds, Scopes) ->
    creds_from_map(json:decode(JsonCreds), Scopes).

creds_from_map(#{<<"project_id">>   := _ProjectId,
                 <<"client_email">> := Iss,
                 <<"private_key">>  := EncodedPrivateKey},
               Scopes) ->
    jwt_bearer_grant(augle_jwt:assertion(Iss, Scopes, EncodedPrivateKey)).

default_path_or_metadata(ServiceAccount) ->
    ConfigPath = get_config_path(),
    CredentialsFile = filename:join(ConfigPath, ?CREDENTIALS_FILENAME),
    case file:read_file(CredentialsFile) of
        {ok, Content} ->
            #{<<"client_id">>     := ClientId,
              <<"client_secret">> := ClientSecret,
              <<"refresh_token">> := RefreshToken,
              <<"type">>          := _Type} = json:decode(Content),
            refresh_grant(RefreshToken, ClientId, ClientSecret);
        _ ->
            %% doesn't exist or we don't have permissions. try instance metadata
            metadata_fetch_token(ServiceAccount)
    end.

get_config_path() ->
    case os:getenv(?CONFIG_DIR) of
        false ->
            {ok, [[Home]]} = init:get_argument(home),
            %% TODO: Windows
            filename:join([Home, ".config", "gcloud"]);
        Dir ->
            Dir
    end.

%%%-----------------------------------------------------------------------------
%%% EXCHANGING THEM FOR AN ACCESS TOKEN
%%%-----------------------------------------------------------------------------
jwt_bearer_grant(Assertion) ->
    Body = uri_string:compose_query([{<<"grant_type">>, ?JWT_GRANT_TYPE},
                                     {<<"assertion">>, Assertion}]),
    post_for_creds(augle_conf:auth_url(), Body).

refresh_grant(RefreshToken, ClientId, ClientSecret) ->
    Body = uri_string:compose_query([{<<"grant_type">>, ?REFRESH_GRANT_TYPE},
                                     {<<"client_id">>, ClientId},
                                     {<<"client_secret">>, ClientSecret},
                                     {<<"refresh_token">>, RefreshToken}]),
    post_for_creds(augle_conf:token_endpoint(), Body).

metadata_fetch_token(ServiceAccount) ->
    creds_response(nhttpc:get(metadata_url(ServiceAccount), #{headers => ?META_HEADERS})).

post_for_creds(Url, Body) ->
    Headers = [{<<"content-type">>, ?URLENCODED_CONTENT_TYPE}],
    creds_response(nhttpc:post(Url, Body, #{headers => Headers})).

metadata_url(ServiceAccount) ->
    Host = augle_conf:metadata_host(),
    <<Host/binary, "/computeMetadata/v1/instance/service-accounts/",
      ServiceAccount/binary, "/token">>.

%% Turns an `nhttpc' result into the public `augle:creds()' shape.
%%
%% Google answers every token endpoint with JSON, so a body we cannot parse
%% means something else answered for it (a proxy, a captive portal) and is
%% reported as an error rather than crashing the caller.
-spec creds_response({ok, nhttp_lib:response()} | {error, term()}) ->
          {ok, augle:creds()} | {error, term()}.
creds_response({ok, #{status := 200} = Response}) ->
    case decode_body(Response) of
        {ok, Json} when is_map(Json) ->
            {ok, creds(Json)};
        {ok, Json} ->
            {error, {unexpected_response, Json}};
        {error, _} = Error ->
            Error
    end;
creds_response({ok, Response}) ->
    case decode_body(Response) of
        {ok, Json} ->
            {error, Json};
        {error, _} = Error ->
            Error
    end;
creds_response({error, Reason}) ->
    {error, Reason}.

decode_body(Response) ->
    Body = iolist_to_binary(maps:get(body, Response, <<>>)),
    try
        {ok, json:decode(Body)}
    catch
        error:Reason ->
            {error, {invalid_json, Reason}}
    end.

%% Google's field names are strings on the wire. Map the ones that make up
%% `augle:creds()' onto atoms explicitly, so no atom is created from a response.
creds(Json) ->
    maps:fold(fun to_creds_key/3, #{}, Json).

to_creds_key(<<"access_token">>, Value, Acc) -> Acc#{access_token => Value};
to_creds_key(<<"expires_in">>, Value, Acc)   -> Acc#{expires_in => Value};
to_creds_key(<<"token_type">>, Value, Acc)   -> Acc#{token_type => Value};
to_creds_key(<<"id_token">>, Value, Acc)     -> Acc#{id_token => Value};
to_creds_key(_Key, _Value, Acc)              -> Acc.
