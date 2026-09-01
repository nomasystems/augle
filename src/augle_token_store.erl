%%%-------------------------------------------------------------------
%%% @author Tristan Sloughter <t@crashfast.com>
%%% @copyright (C) 2017, Tristan Sloughter
%%% @doc Cache of access tokens, keyed on how the credentials were fetched.
%%%
%%% Two paths, and under steady load only the first one is ever taken:
%%%
%%%   * a timer refreshes each token `refresh_margin' seconds before it
%%%     expires, in a process of its own, leaving the cached token in place
%%%     while it does. Readers keep being served the old one, which is still
%%%     valid, so a caller is never caught waiting on a token exchange.
%%%   * a cold cache, or a refresh that failed, falls through to a fetch
%%%     serialised on this server, so a burst of concurrent misses on the same
%%%     credentials costs one request rather than one each.
%%% @end
%%% Created : 16 Sep 2017 by Tristan Sloughter <t@crashfast.com>
%%%-------------------------------------------------------------------
-module(augle_token_store).

-behaviour(gen_server).

-export([start_link/0,
         lookup/1,
         fetch/1,
         flush/0]).

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-define(SERVER, ?MODULE).
-define(TOKEN_CACHE, token_ets_cache).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Reads the cache directly, no message to the server. This is the hot
%% path: every call that already has a valid token ends here.
%%
%% The row carries the instant the token stops being served rather than the one
%% it expires at, so the margin is applied once on write and this stays a bare
%% lookup and a comparison.
-spec lookup(augle:credentials_format()) -> augle:creds() | notfound.
lookup(CredsFrom) ->
    Now = erlang:monotonic_time(second),
    case ets:lookup(?TOKEN_CACHE, CredsFrom) of
        [{CredsFrom, Creds, ServeUntil}] when ServeUntil > Now ->
            Creds;
        _ ->
            notfound
    end.

%% @doc Fetches credentials and caches them, serialised through the server.
-spec fetch(augle:credentials_format()) -> {ok, augle:creds()} | {error, term()}.
fetch(CredsFrom) ->
    gen_server:call(?SERVER, {fetch, CredsFrom}, augle_conf:fetch_timeout()).

%% @doc Drops every cached token, for instance after rotating a key.
-spec flush() -> ok.
flush() ->
    gen_server:call(?SERVER, flush).

%%%-----------------------------------------------------------------------------
%%% gen_server CALLBACKS
%%%-----------------------------------------------------------------------------
init([]) ->
    ?TOKEN_CACHE = ets:new(?TOKEN_CACHE, [named_table, set, protected,
                                          {read_concurrency, true}]),
    {ok, #{timers => #{}}}.

handle_call({fetch, CredsFrom}, _From, #{timers := Timers} = State) ->
    case lookup(CredsFrom) of
        notfound ->
            case new_creds(CredsFrom) of
                {ok, Creds} ->
                    {reply, {ok, Creds}, State#{timers := cache(CredsFrom, Creds, Timers)}};
                {error, Reason} ->
                    {reply, {error, Reason}, State}
            end;
        Creds ->
            {reply, {ok, Creds}, State}
    end;
handle_call(flush, _From, #{timers := Timers} = State) ->
    _ = maps:foreach(fun(_CredsFrom, Ref) -> cancel(Ref) end, Timers),
    true = ets:delete_all_objects(?TOKEN_CACHE),
    {reply, ok, State#{timers := #{}}};
handle_call(Msg, _From, State) ->
    {reply, {error, {unknown_call, Msg}}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({timeout, _Ref, {refresh, CredsFrom}}, #{timers := Timers} = State) ->
    Server = self(),
    _ = erlang:spawn(fun() -> Server ! {refreshed, CredsFrom, new_creds(CredsFrom)} end),
    {noreply, State#{timers := maps:remove(CredsFrom, Timers)}};
handle_info({refreshed, CredsFrom, {ok, Creds}}, #{timers := Timers} = State) ->
    {noreply, State#{timers := cache(CredsFrom, Creds, Timers)}};
handle_info({refreshed, _CredsFrom, {error, _Reason}}, State) ->
    {noreply, State};
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%-----------------------------------------------------------------------------
%%% INTERNAL
%%%-----------------------------------------------------------------------------
new_creds(CredsFrom) ->
    try augle:new_creds_from(CredsFrom) of
        {ok, Creds} ->
            {ok, Creds};
        {error, Reason} ->
            {error, Reason}
    catch
        Class:Reason:Stacktrace ->
            {error, {credentials_error, Class, Reason, Stacktrace}}
    end.

cache(CredsFrom, #{expires_in := ExpiresIn} = Creds, Timers0) ->
    Timers = cancel_refresh(CredsFrom, Timers0),
    case ExpiresIn - augle_conf:expiry_margin() of
        ServeFor when ServeFor > 0 ->
            ServeUntil = erlang:monotonic_time(second) + ServeFor,
            true = ets:insert(?TOKEN_CACHE, {CredsFrom, Creds, ServeUntil}),
            schedule_refresh(CredsFrom, ExpiresIn, Timers);
        _ ->
            %% shorter lived than the margin, so it could never be served from
            %% the cache anyway. Caching it would only spin the refresh.
            true = ets:delete(?TOKEN_CACHE, CredsFrom),
            Timers
    end.

schedule_refresh(CredsFrom, ExpiresIn, Timers) ->
    case ExpiresIn - augle_conf:refresh_margin() of
        RefreshIn when RefreshIn > 0 ->
            After = erlang:convert_time_unit(RefreshIn, second, millisecond),
            Ref = erlang:start_timer(After, self(), {refresh, CredsFrom}),
            Timers#{CredsFrom => Ref};
        _ ->
            Timers
    end.

cancel_refresh(CredsFrom, Timers) ->
    case maps:take(CredsFrom, Timers) of
        {Ref, Rest} ->
            cancel(Ref),
            Rest;
        error ->
            Timers
    end.

cancel(Ref) ->
    _ = erlang:cancel_timer(Ref, [{async, true}, {info, false}]),
    ok.
