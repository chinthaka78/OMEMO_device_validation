-module(mod_omemo_validate).

-behaviour(gen_mod).

-export([start/2, 
	stop/1, 
	depends/2, 
	mod_options/1, 
	mod_doc/0, 
	user_send_packet/1, 
	user_send_packet/4]).

-include("pubsub.hrl").
-include("xmpp.hrl").
-include("logger.hrl").

%% gen_mod callbacks
start(Host, _Opts) ->
    ?INFO_MSG("Starting mod_omemo_validate for host ~p", [Host]),
    ejabberd_hooks:add(user_send_packet, Host, ?MODULE, user_send_packet, 90),
    ok.

stop(Host) ->
    ?INFO_MSG("Stopping mod_omemo_validate for host ~p", [Host]),
    ejabberd_hooks:delete(user_send_packet, Host, ?MODULE, user_send_packet, 90),
    ok.

depends(_Host, _Opts) ->
    [{mod_pubsub, hard}]. % Requires mod_pubsub

mod_options(_Host) ->
    []. % No configuration options needed

mod_doc() ->
    #{desc => "Validates OMEMO device IDs before forwarding messages."}.

%% Hook to validate OMEMO device IDs
user_send_packet({#message{type = Type,
			    from = From,
			    to = To,
				id = Id} = Packet, State}) ->
	?INFO_MSG("mod_omemo_validate user_send_packet 1 ~p", [{Type, From, To}]),
    case xmpp:get_type(Packet) of
        chat ->
			?INFO_MSG("mod_omemo_validate user_send_packet 2 ~p", [{Type, From, To}]),
            case extract_omemo_payload(Packet) of
                {ok, DeviceIDs} ->
					?INFO_MSG("mod_omemo_validate user_send_packet DeviceIDs ~p", [DeviceIDs]),
                    case validate_device_ids(To, DeviceIDs) of
                        ok ->
                            {Packet, State};
                        {error, InvalidIDs} ->
                            ?ERROR_MSG("Invalid device IDs ~p for ~p", [InvalidIDs, To]),
                            send_error_stanza(From, To, Id),
                            stop
                    end;
                none ->
					?INFO_MSG("mod_omemo_validate user_send_packet DeviceIDs ~p", [none]),
                    {Packet, State}
            end;
        _ ->
            {Packet, State}
    end;
user_send_packet(Acc) ->	
	%%?INFO_MSG("mod_omemo_validate user_send_packet 3 ~p", [Acc]),
	%%Nothing to do here. just return the received data without changes
	Acc.
%% Hook to validate OMEMO device IDs
user_send_packet(#message{id = Id} = Packet, _C2SState, From, To) ->
    case xmpp:get_type(Packet) of
        chat ->
            case extract_omemo_payload(Packet) of
                {ok, DeviceIDs} ->
                    case validate_device_ids(To, DeviceIDs) of
                        ok ->
                            Packet;
                        {error, InvalidIDs} ->
                            ?ERROR_MSG("Invalid device IDs ~p for ~p", [InvalidIDs, To]),
                            send_error_stanza(From, To, Id),
                            stop
                    end;
                none ->
                    Packet
            end;
        _ ->
            Packet
    end.


%% Extract device IDs from OMEMO payload
extract_omemo_payload(#message{sub_els = SubEls} = Packet) ->
    ?INFO_MSG("Extracting OMEMO payload from sub_els: ~p", [SubEls]),
    case lists:keyfind(<<"encrypted">>, #xmlel.name, SubEls) of
        #xmlel{name = <<"encrypted">>, attrs = Attrs, children = Children} ->
            ?INFO_MSG("Found encrypted element, children: ~p", [Children]),
            case lists:keyfind(<<"xmlns">>, 1, Attrs) of
                {<<"xmlns">>, NS} when NS =:= <<"urn:xmpp:omemo:0">> orelse NS =:= <<"eu.siacs.conversations.axolotl">> ->
                    DeviceIDs = lists:flatmap(
                        fun(#xmlel{name = <<"header">>, children = HeaderChildren}) ->
                            ?INFO_MSG("Processing header children: ~p", [HeaderChildren]),
                            lists:flatmap(
                                fun(#xmlel{name = <<"key">>, attrs = KeyAttrs}) ->
                                    case lists:keyfind(<<"rid">>, 1, KeyAttrs) of
                                        {<<"rid">>, ID} ->
                                            [binary_to_integer(ID)];
                                        _ ->
                                            ?INFO_MSG("No rid in key attrs: ~p", [KeyAttrs]),
                                            []
                                    end;
                                    (#xmlel{name = Name, attrs = Attrs}) ->
                                        ?INFO_MSG("Ignoring xmlel in header: ~p, attrs: ~p", [Name, Attrs]),
                                        [];
                                    ({xmlcdata, Data}) ->
                                        ?INFO_MSG("Ignoring CDATA in header: ~p", [Data]),
                                        []
                                end, HeaderChildren);
                            (#xmlel{name = Name, attrs = Attrs}) ->
                                ?INFO_MSG("Ignoring xmlel in encrypted: ~p, attrs: ~p", [Name, Attrs]),
                                [];
                            ({xmlcdata, Data}) ->
                                ?INFO_MSG("Ignoring CDATA in encrypted: ~p", [Data]),
                                []
                        end, Children),
                    ?INFO_MSG("Extracted OMEMO payload device IDs (xmlns=~s): ~p", [NS, DeviceIDs]),
                    {ok, DeviceIDs};
                _ ->
                    ?INFO_MSG("Non-OMEMO encrypted element found in sub_els (xmlns=~p)", [proplists:get_value(<<"xmlns">>, Attrs, <<"unknown">>)]),
                    none
            end;
        _ ->
            ?INFO_MSG("No encrypted element in sub_els", []),
            none
    end.

%% Validate device IDs against receiver's PubSub device list
validate_device_ids(To, DeviceIDs) ->
    Host = To#jid.lserver,
    User = To#jid.luser,
    Node = <<"eu.siacs.conversations.axolotl.devicelist">>,
    ?DEBUG("Validating device IDs ~p for ~p@~p, node ~p", [DeviceIDs, User, Host, Node]),
	
	%%DeviceIds = get_device_ids(User, Host),
	%%?INFO_MSG(">>>>>>>>>>>> device IDs for ~p@~p: ~p", [DeviceIds]),
    %%case mod_pubsub:get_items(Host, Node, User) of
	case get_device_ids(User, Host) of
        {ok, ValidIDs} ->
            %?DEBUG("Retrieved PubSub items: ~p", [Items]),
            %ValidIDs = lists:flatmap(
            %    fun(#pubsub_item{payload = Payload}) ->
            %        case lists:keyfind(<<"list">>, #xmlel.name, Payload) of
            %            #xmlel{name = <<"list">>, children = DeviceNodes} ->
            %                lists:flatmap(
            %                    fun(#xmlel{name = <<"device">>, attrs = Attrs}) ->
            %                        case lists:keyfind(<<"id">>, 1, Attrs) of
            %                            {<<"id">>, ID} ->
            %                                [binary_to_integer(ID)];
            %                            _ ->
            %                                ?DEBUG("No id in device attrs: ~p", [Attrs]),
            %                                []
            %                        end;
            %                        (#xmlel{name = Name, attrs = Attrs}) ->
            %                            ?DEBUG("Ignoring xmlel in device list: ~p, attrs: ~p", [Name, Attrs]),
            %                            [];
            %                        ({xmlcdata, Data}) ->
            %                            ?DEBUG("Ignoring CDATA in device list: ~p", [Data]),
            %                            []
            %                    end, DeviceNodes);
            %            _ ->
            %                ?DEBUG("No list element in payload", []),
            %                []
            %        end
            %    end, Items),
			%DeviceIDs2 = [11111],
            ?INFO_MSG("Valid device IDs for ~p@~p: ~p", [User, Host, ValidIDs]),
            InvalidIDs = [ID || ID <- DeviceIDs, not lists:member(ID, ValidIDs)],
            case InvalidIDs of
                [] ->
                    ?INFO_MSG("All device IDs valid for ~p@~p", [User, Host]),
                    ok;
                _ ->
                    ?ERROR_MSG("Found invalid device IDs ~p for ~p@~p", [InvalidIDs, User, Host]),
                    {error, InvalidIDs}
            end;
        {error, Reason} ->
            ?ERROR_MSG("Failed to fetch device list for ~p@~p: ~p", [User, Host, Reason]),
            {error, DeviceIDs}
    end.

%%--------------------------------------------------------------------
%% Fetch OMEMO device IDs from pubsub_item table for a given user node
%% Example:
%%   get_device_ids(<<"bob3">>, <<"localhost">>).
%%--------------------------------------------------------------------
get_device_ids(User, Server) ->
    %%{pubsub_node,{{<<"bob3">>,<<"localhost">>,<<>>},
    %%           <<"eu.siacs.conversations.axolotl.bundles:1383904352">>},
    %%          2,[],<<"pep">>,
	NodeId = {{User, Server, <<>>}, <<"eu.siacs.conversations.axolotl.devicelist">>},

    %%Lookup the pubsub_node record
    case mnesia:dirty_read({pubsub_node, NodeId}) of
        [#pubsub_node{id = NodeIdx}] ->
            ?INFO_MSG("Found node id: ~p~n", [NodeIdx]),

            %%Select matching pubsub_item entries by NodeIdx
			%%[{pubsub_item,
			%%	 {<<"6E171E86302B4">>,1},
			%%	 1,
			%%	 {{1761,466566,199089},{<<"bob3">>,<<"localhost">>,<<>>}},
			%%	 {{1761,466566,199089},
			%%	  {<<"bob3">>,<<"localhost">>,<<"LKCOL-WN-ENG-ChinthakaG">>}},
			%%	 [{xmlel,<<"list">>,
			%%		  [{<<"xmlns">>,<<"eu.siacs.conversations.axolotl">>}],
			%%		  [{xmlcdata,<<"\n   ">>},
			%%		   {xmlel,<<"device">>,[{<<"id">>,<<"1383904352">>}],[]},
			%%		   {xmlcdata,<<"\n  ">>}]}]},
            Items = mnesia:dirty_select(pubsub_item, [
                {#pubsub_item{itemid = {'_', '$1'}, _ = '_'},
                 [{'==', '$1', NodeIdx}],
                 ['$_']}
            ]),

            %% Extract device ids
            DeviceIds = [binary_to_integer(Id) || {pubsub_item, _, _, _, _, Payload} <- Items,
                                  {xmlel, <<"list">>, _, Children} <- Payload,
                                  {xmlel, <<"device">>, Attrs, _} <- Children,
                                  {<<"id">>, Id} <- Attrs],
            {ok, DeviceIds};

        [] ->
            {error, node_not_found}
    end.
	
%% Extract device IDs from OMEMO payload
%extract_omemo_payload(#message{body = Body} = Packet) ->
%	?INFO_MSG("mod_omemo_validate extract_omemo_payload Packet ~p", [Packet]),
%    case lists:keyfind(<<"encrypted">>, #xmlel.name, Body) of
%        #xmlel{name = <<"encrypted">>, attrs = Attrs, children = Children} ->
%            case lists:keyfind(<<"xmlns">>, 1, Attrs) of
%                {<<"xmlns">>, NS} when NS =:= <<"urn:xmpp:omemo:0">> orelse NS =:= <<"eu.siacs.conversations.axolotl">> ->
%                    DeviceIDs = lists:flatmap(
%                        fun(#xmlel{name = <<"key">>, attrs = PAttrs}) ->
%                            case lists:keyfind(<<"rid">>, 1, PAttrs) of
%                                {<<"rid">>, ID} ->
%                                    [binary_to_integer(ID)];
%                                _ ->
%                                    []
%                            end
%                        end, Children),
%                    ?INFO_MSG("Extracted OMEMO payload device IDs (xmlns=~s): ~p", [NS, DeviceIDs]),
%                    {ok, DeviceIDs};
%                _ ->
%                    ?INFO_MSG("Non-OMEMO encrypted element found in message body", []),
%                    none
%            end;
%        _ ->
%            ?INFO_MSG("No encrypted element in message body", []),
%            none
%    end.
%
%%% Validate device IDs against receiver's PubSub device list
%validate_device_ids(To, DeviceIDs) ->
%    Host = To#jid.lserver,
%    User = To#jid.luser,
%    Node = <<"eu.siacs.conversations.axolotl.devicelist">>,
%    case mod_pubsub:get_items(Host, Node, User) of
%        {ok, Items} ->
%            ValidIDs = lists:flatmap(
%                fun(#pubsub_item{payload = Payload}) ->
%                    case lists:keyfind(<<"list">>, #xmlel.name, Payload) of
%                        #xmlel{name = <<"list">>, children = DeviceNodes} ->
%                            lists:flatmap(
%                                fun(#xmlel{name = <<"device">>, attrs = Attrs}) ->
%                                    case lists:keyfind(<<"id">>, 1, Attrs) of
%                                        {<<"id">>, ID} -> [binary_to_integer(ID)];
%                                        _ -> []
%                                    end
%                                end, DeviceNodes);
%                        _ -> []
%                    end
%                end, Items),
%            InvalidIDs = [ID || ID <- DeviceIDs, not lists:member(ID, ValidIDs)],
%            case InvalidIDs of
%                [] -> ok;
%                _ -> {error, InvalidIDs}
%            end;
%        {error, _Reason} ->
%            ?ERROR_MSG("Failed to fetch device list for ~p: ~p", [To, _Reason]),
%            {error, DeviceIDs}
%    end.

%% Send error stanza to sender
send_error_stanza(From, To, Id) ->
    Error = #xmlel{
        name = <<"error">>,
        attrs = [{<<"type">>, <<"modify">>}],
        children = [
            #xmlel{name = <<"device-id-invalid">>, attrs = [{<<"xmlns">>, <<"urn:xmpp:errors">>}]},
            #xmlel{name = <<"text">>, children = [{xmlcdata, <<"Device ID not valid">>}]}
        ]
    },
    ErrorMsg = #message{
        type = error,
        from = To,
        to = From,
		id = Id,
        %%id = xmpp:make_id(),
        sub_els = [Error]
    },
    ejabberd_router:route(ErrorMsg).