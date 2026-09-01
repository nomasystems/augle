%%%-------------------------------------------------------------------
%%% @author Sito <sito@nomasystems.com>
%%% @copyright (C) 2024, Nomasystems
%%% @doc
%%%
%%% @end
%%% Created : 16 Aug 2024 by Sito <sito@nomasystems.com>
%%%-------------------------------------------------------------------
-module(augle_conf).

%%% EXTERNAL EXPORTS
-export([
    auth_host/0,
    auth_path/0,
    auth_url/0,
    metadata_host/0,
    token_endpoint/0,
    fetch_timeout/0,
    expiry_margin/0,
    refresh_margin/0
]).

-define(AUTH_HOST, <<"https://www.googleapis.com">>).
-define(AUTH_PATH, <<"/oauth2/v4/token">>).
-define(METADATA_HOST, <<"http://metadata.google.internal">>).
-define(TOKEN_ENDPOINT, <<"https://accounts.google.com/o/oauth2/token">>).
-define(FETCH_TIMEOUT, 40000).
-define(EXPIRY_MARGIN, 10).
-define(REFRESH_MARGIN, 60).

%%%-----------------------------------------------------------------------------
%%% EXTERNAL EXPORTS
%%%-----------------------------------------------------------------------------
auth_host() ->
    application:get_env(augle, auth_host, ?AUTH_HOST).

auth_path() ->
    application:get_env(augle, auth_path, ?AUTH_PATH).

%% The endpoint we post the assertion to, and the `aud' claim inside it.
auth_url() ->
    AuthHost = auth_host(),
    AuthPath = auth_path(),
    <<AuthHost/binary, AuthPath/binary>>.

%% Override to point at a GCE metadata emulator during development.
metadata_host() ->
    application:get_env(augle, metadata_host, ?METADATA_HOST).

token_endpoint() ->
    application:get_env(augle, token_endpoint, ?TOKEN_ENDPOINT).

fetch_timeout() ->
    application:get_env(augle, fetch_timeout, ?FETCH_TIMEOUT).

expiry_margin() ->
    application:get_env(augle, expiry_margin, ?EXPIRY_MARGIN).

refresh_margin() ->
    application:get_env(augle, refresh_margin, ?REFRESH_MARGIN).
