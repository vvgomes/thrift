%%
%% Licensed to the Apache Software Foundation (ASF) under one
%% or more contributor license agreements. See the NOTICE file
%% distributed with this work for additional information
%% regarding copyright ownership. The ASF licenses this file
%% to you under the Apache License, Version 2.0 (the
%% "License"); you may not use this file except in compliance
%% with the License. You may obtain a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied. See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%

-module(thrift_http_transport).

-behaviour(gen_server).
-behaviour(thrift_transport).

%% API
-export([new/2, new/3]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

%% thrift_transport callbacks
-export([write/2, read/2, flush/1, close/1]).

-record(http_transport, {host, % string()
                         path, % string()
                         read_buffer, % iolist()
                         write_buffer, % iolist()
                         http_options, % see http(3)
                         extra_headers % [{str(), str()}, ...]
                        }).
-type state() :: pid().
-include("thrift_transport_impl.hrl").

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: new() -> {ok, Transport} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
new(Host, Path) ->
    new(Host, Path, _Options = []).

%%--------------------------------------------------------------------
%% Options include:
%%   {http_options, HttpOptions}  = See http(3)
%%   {extra_headers, ExtraHeaders}  = List of extra HTTP headers
%%--------------------------------------------------------------------
new(Host, Path, Options) ->
    case gen_server:start_link(?MODULE, {Host, Path, Options}, []) of
        {ok, Pid} ->
            thrift_transport:new(?MODULE, Pid);
        Else ->
            Else
    end.

%%--------------------------------------------------------------------
%% Function: write(Transport, Data) -> ok
%%
%% Data = iolist()
%%
%% Description: Writes data into the buffer
%%--------------------------------------------------------------------
write(Transport, Data) ->
    {Transport, gen_server:call(Transport, {write, Data})}.

%%--------------------------------------------------------------------
%% Function: flush(Transport) -> ok
%%
%% Description: Flushes the buffer, making a request
%%--------------------------------------------------------------------
flush(Transport) ->
    {Transport, gen_server:call(Transport, flush)}.

%%--------------------------------------------------------------------
%% Function: close(Transport) -> ok
%%
%% Description: Closes the transport
%%--------------------------------------------------------------------
close(Transport) ->
    {Transport, gen_server:cast(Transport, close)}.

%%--------------------------------------------------------------------
%% Function: Read(Transport, Len) -> {ok, Data}
%%
%% Data = binary()
%%
%% Description: Reads data through from the wrapped transoprt
%%--------------------------------------------------------------------
read(Transport, Len) when is_integer(Len) ->
    {Transport, gen_server:call(Transport, {read, Len})}.

%%====================================================================
%% gen_server callbacks
%%====================================================================

init({Host, Path, Options}) ->
    State1 = #http_transport{host = Host,
                             path = Path,
                             read_buffer = [],
                             write_buffer = [],
                             http_options = [],
                             extra_headers = []},
    ApplyOption =
        fun
            ({http_options, HttpOpts}, State = #http_transport{}) ->
                State#http_transport{http_options = HttpOpts};
            ({extra_headers, ExtraHeaders}, State = #http_transport{}) ->
                State#http_transport{extra_headers = ExtraHeaders};
            (Other, #http_transport{}) ->
                {invalid_option, Other};
            (_, Error) ->
                Error
        end,
    case lists:foldl(ApplyOption, State1, Options) of
        State2 = #http_transport{} ->
            {ok, State2};
        Else ->
            {stop, Else}
    end.

handle_call({write, Data}, _From, State = #http_transport{write_buffer = WBuf}) ->
    {reply, ok, State#http_transport{write_buffer = [WBuf, Data]}};

handle_call({read, Len}, _From, State = #http_transport{read_buffer = RBuf}) ->
    %% Pull off Give bytes, return them to the user, leave the rest in the buffer.
    Give = min(iolist_size(RBuf), Len),
    case iolist_to_binary(RBuf) of
        <<Data:Give/binary, RBuf1/binary>> ->
            Response = {ok, Data},
            State1 = State#http_transport{read_buffer=RBuf1},
            {reply, Response, State1};
        _ ->
            {reply, {error, 'EOF'}, State}
    end;

handle_call(flush, _From, State) ->
    {Response, State1} = do_flush(State),
    {reply, Response, State1}.

handle_cast(close, State) ->
    {_, State1} = do_flush(State),
    {stop, normal, State1};

handle_cast(_Msg, State=#http_transport{}) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
do_flush(State = #http_transport{host = Host,
                                 path = Path,
                                 read_buffer = Rbuf,
                                 write_buffer = Wbuf,
                                 http_options = HttpOptions,
                                 extra_headers = ExtraHeaders}) ->
    case iolist_to_binary(Wbuf) of
        <<>> ->
            %% Don't bother flushing empty buffers.
            {ok, State};
        WBinary ->
            {ok, {{_Version, 200, _ReasonPhrase}, _Headers, Body}} =
              http:request(post,
                           {"http://" ++ Host ++ Path,
                            [{"User-Agent", "Erlang/thrift_http_transport"} | ExtraHeaders],
                            "application/x-thrift",
                            WBinary},
                           HttpOptions,
                           [{body_format, binary}]),

            State1 = State#http_transport{read_buffer = [Rbuf, Body],
                                          write_buffer = []},
            {ok, State1}
    end.

min(A,B) when A<B -> A;
min(_,B)          -> B.
