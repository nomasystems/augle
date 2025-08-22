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
    auth_path/0
]).

-define(AUTH_HOST, <<"https://www.googleapis.com">>).
-define(AUTH_PATH, <<"/oauth2/v4/token">>).

%%%-----------------------------------------------------------------------------
%%% EXTERNAL EXPORTS
%%%-----------------------------------------------------------------------------
auth_host() ->
    application:get_env(augle, auth_host, ?AUTH_HOST).

auth_path() ->
    application:get_env(augle, auth_path, ?AUTH_PATH).