%%%-------------------------------------------------------------------
%%% @doc A stand-in for Google's token and metadata endpoints.
%%%
%%% Replaces the `hackney' mocks the suite used to carry: `augle' talks to
%%% this over a real socket, so the request it builds is exercised end to end.
%%% @end
%%%-------------------------------------------------------------------
-module(augle_test_google).

-behaviour(nhttp_handler).

%% nhttp_handler
-export([init/1,
         handle_request/2,
         handle_request_body/3]).

%% test API
-export([start/0,
         stop/1,
         respond_with/1,
         requests/0,
         reset/0]).

-define(TABLE, ?MODULE).
-define(RESPONDER, {?MODULE, responder}).

%%%-----------------------------------------------------------------------------
%%% TEST API
%%%-----------------------------------------------------------------------------

%% @doc Starts the server on an ephemeral port, owned by a process that outlives
%% the common_test process calling this.
-spec start() -> {ok, pid(), inet:port_number()}.
start() ->
    Caller = self(),
    Owner = spawn(fun() ->
                      ?TABLE = ets:new(?TABLE, [named_table, public, ordered_set]),
                      {ok, Pid} = nhttp:start_link(#{port => 0, handler => ?MODULE}),
                      {ok, Port} = nhttp:get_port(Pid),
                      Caller ! {started, self(), Port},
                      receive
                          stop -> nhttp:stop(Pid)
                      end
                  end),
    receive
        {started, Owner, Port} ->
            {ok, Owner, Port}
    after 5000 ->
        error(server_start_timeout)
    end.

-spec stop(pid()) -> ok.
stop(Owner) ->
    Owner ! stop,
    ok.

%% @doc Sets what the server answers. Either a fixed JSON body (200), a
%% `{Status, Body}' pair, or a fun of the request for per-request answers.
-spec respond_with(fun((nhttp_lib:request()) -> nhttp_lib:response()) |
                   {nhttp_lib:status(), iodata()} |
                   map()) -> ok.
respond_with(Fun) when is_function(Fun, 1) ->
    persistent_term:put(?RESPONDER, Fun);
respond_with({Status, Body}) ->
    respond_with(fun(_Req) -> response(Status, Body) end);
respond_with(Json) when is_map(Json) ->
    respond_with(fun(_Req) -> response(200, json:encode(Json)) end).

%% @doc Every request the server has seen since the last `reset/0', in order.
-spec requests() -> [nhttp_lib:request()].
requests() ->
    [Req || {_Seq, Req} <- ets:tab2list(?TABLE)].

-spec reset() -> ok.
reset() ->
    ets:delete_all_objects(?TABLE),
    persistent_term:erase(?RESPONDER),
    ok.

%%%-----------------------------------------------------------------------------
%%% nhttp_handler
%%%-----------------------------------------------------------------------------
init(_Args) ->
    {ok, #{}}.

handle_request(#{body := streaming} = Req, State) ->
    %% buffer the body so tests can assert on what augle actually sent
    {accept_body, {Req, []}, State};
handle_request(Req, State) ->
    {reply, respond(Req), State}.

handle_request_body({data, Data}, {Req, Acc}, State) ->
    {accept_body, {Req, [Data | Acc]}, State};
handle_request_body({fin, _Trailers}, {Req, Acc}, State) ->
    Body = iolist_to_binary(lists:reverse(Acc)),
    {reply, respond(Req#{body => Body}), State};
handle_request_body({abort, Reason}, _BodyState, State) ->
    {abort, Reason, State}.

%%%-----------------------------------------------------------------------------
%%% INTERNAL
%%%-----------------------------------------------------------------------------
respond(Req) ->
    ets:insert(?TABLE, {erlang:unique_integer([monotonic]), Req}),
    Responder = persistent_term:get(?RESPONDER, fun not_configured/1),
    Responder(Req).

response(Status, Body) ->
    #{status => Status,
      headers => [{<<"content-type">>, <<"application/json">>}],
      body => Body}.

not_configured(_Req) ->
    response(500, <<"{\"error\":\"no responder configured for this test\"}">>).
