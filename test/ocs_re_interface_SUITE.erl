%%% ocs_re_interface_SUITE.erl
%%% vim: ts=3
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @copyright 2016 - 2021 SigScale Global Inc.
%%% @end
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%  @doc Test suite for public API of the {@link //ocs. ocs} application.
%%%
-module(ocs_re_interface_SUITE).
-copyright('Copyright (c) 2016 - 2021 SigScale Global Inc.').

%% common_test required callbacks
-export([suite/0, sequences/0, all/0]).
-export([init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).

%% Note: This directive should only be used in test suites.
-compile(export_all).

-include_lib("radius/include/radius.hrl").
-include("ocs_eap_codec.hrl").
-include("ocs.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("inets/include/mod_auth.hrl").
-include_lib("diameter/include/diameter.hrl").
-include_lib("diameter/include/diameter_gen_base_rfc6733.hrl").
-include_lib("../include/diameter_gen_nas_application_rfc7155.hrl").
-include_lib("../include/diameter_gen_cc_application_rfc4006.hrl").
-include_lib("../include/diameter_gen_3gpp_ro_application.hrl").
-include_lib("../include/diameter_gen_3gpp.hrl").
-include_lib("../include/diameter_gen_ietf.hrl").

-define(RO_APPLICATION_ID, 4).
-define(IANA_PEN_3GPP, 10415).
-define(IANA_PEN_SigScale, 50386).
-define(NRF_RO_APPLICATION_CALLBACK, ocs_diameter_3gpp_ro_nrf_app_cb).

%% support deprecated_time_unit()
-define(MILLISECOND, milli_seconds).
%-define(MILLISECOND, millisecond).

%%---------------------------------------------------------------------
%%  Test server callback functions
%%---------------------------------------------------------------------

-spec suite() -> DefaultData :: [tuple()].
%% Require variables and set default values for the suite.
%%
suite() ->
   [{userdata, [{doc, "Test suite for REST API in OCS"}]},
   {timetrap, {minutes, 10}}].

-spec init_per_suite(Config :: [tuple()]) -> Config :: [tuple()].
%% Initialization before the whole suite.
%%
init_per_suite(Config) ->
	ok = ocs_test_lib:initialize_db(),
   ok = ocs_test_lib:load(ocs),
	Address = {127,0,0,1},
	TempNrfPath = "http://127.0.0.1",
	ok = application:set_env(ocs, nrf_uri, TempNrfPath),
   Realm = "acct.sigscale.org",
	Host = atom_to_list(?MODULE),
	DiameterAuthPort = rand:uniform(64511) + 1024,
   DiameterAcctPort = rand:uniform(64511) + 1024,
   DiameterAppVar = [{auth, [{Address, DiameterAuthPort, []}]},
      {acct, [{Address, DiameterAcctPort, []}]}],
   ok = application:set_env(ocs, diameter, DiameterAppVar),
   ok = application:set_env(ocs, min_reserve_octets, 1000000),
   ok = application:set_env(ocs, min_reserve_seconds, 60),
   ok = application:set_env(ocs, min_reserve_messages, 1),
   ok = ocs_test_lib:start(),
   Config1 = [{diameter_host, Host}, {realm, Realm},
         {diameter_acct_address, Address} | Config],
   ok = diameter:start_service(?MODULE, client_acct_service_opts(Config1)),
   true = diameter:subscribe(?MODULE),
   {ok, _Ref2} = connect(?MODULE, Address, DiameterAcctPort, diameter_tcp),
   receive
      #diameter_event{service = ?MODULE, info = Info}
            when element(1, Info) == up ->
			start1(Config1);
      _Other ->
         {skip, diameter_client_acct_service_not_started}
   end.
start1(Config) ->
	case inets:start(httpd,
			[{port, 0},
			{server_name, atom_to_list(?MODULE)},
			{server_root, "./"},
			{document_root, ?config(data_dir, Config)},
			{modules, [mod_ct_nrf]}]) of
		{ok, HttpdPid} ->
			[{port, Port}] = httpd:info(HttpdPid, [port]),
			NrfUri = "http://localhost:" ++ integer_to_list(Port),
			ok = application:set_env(ocs, nrf_uri, NrfUri),
			[{server_port, Port},
					{server_pid, HttpdPid} | Config];
		{error, InetsReason} ->
			ct:fail(InetsReason)
	end.

-spec end_per_suite(Config :: [tuple()]) -> any().
%% Cleanup after the whole suite.
%%
end_per_suite(Config) ->
	ok = ocs_test_lib:stop(),
	Config.

-spec init_per_testcase(TestCase :: atom(), Config :: [tuple()]) -> Config :: [tuple()].
%% Initialization before each test case.
%%
init_per_testcase(TestCase, Config)
		when TestCase == send_initial_scur; TestCase == receive_initial_scur;
		TestCase == send_interim_scur; TestCase == receive_interim_scur;
		TestCase == send_final_scur; TestCase == receive_final_scur;
		TestCase == receive_interim_no_usu_scur ->
	Address = ?config(diameter_acct_address, Config),
	{ok, _} = ocs:add_client(Address, undefined, diameter, undefined, true),
	Config;
init_per_testcase(_TestCase, Config) ->
	Config.

-spec end_per_testcase(TestCase :: atom(), Config :: [tuple()]) -> any().
%% Cleanup after each test case.
%%
end_per_testcase(_TestCase, _Config) ->
	ok.

-spec sequences() -> Sequences :: [{SeqName :: atom(), Testcases :: [atom()]}].
%% Group test cases into a test sequence.
%%
sequences() -> 
	[].

-spec all() -> TestCases :: [Case :: atom()].
%% Returns a list of all test cases in this test suite.
%%
all() -> 
	[send_initial_scur, receive_initial_scur, send_interim_scur,
		receive_interim_scur, send_final_scur, receive_final_scur,
		receive_interim_no_usu_scur].

%%---------------------------------------------------------------------
%%  Test cases
%%---------------------------------------------------------------------

send_initial_scur() ->
	[{userdata, [{doc, "On received SCUR CCR-I sendstartRating"}]}].

send_initial_scur(_Config) ->
	P1 = price(usage, octets, rand:uniform(10000000), rand:uniform(1000000)),
	OfferId = add_offer([P1], 4),
	ProdRef = add_product(OfferId),
	MSISDN = list_to_binary(ocs:generate_identity()),
	IMSI = list_to_binary(ocs:generate_identity()),
	Subscriber = {MSISDN, IMSI},
	Password = ocs:generate_identity(),
	{ok, #service{}} = ocs:add_service(MSISDN, Password, ProdRef, []),
	Balance = rand:uniform(1000000000),
	B1 = bucket(octets, Balance),
	_BId = add_bucket(ProdRef, B1),
	Ref = erlang:ref_to_list(make_ref()),
   SId = diameter:session_id(Ref),
   RequestNum = 0,
	InputOctets = rand:uniform(Balance),
	OutputOctets = rand:uniform(Balance),
	RequestedServiceUnits = {InputOctets, OutputOctets},
   Answer0 = diameter_scur_start(SId, Subscriber, RequestNum, RequestedServiceUnits),
	#'3gpp_ro_CCA'{'Result-Code' = ?'DIAMETER_BASE_RESULT-CODE_SUCCESS'} = Answer0.

receive_initial_scur() ->
	[{userdata, [{doc, "On SCUR startRating response send CCA-I"}]}].

receive_initial_scur(_Config) ->
	P1 = price(usage, octets, rand:uniform(10000000), rand:uniform(1000000)),
	OfferId = add_offer([P1], 4),
	ProdRef = add_product(OfferId),
	MSISDN = list_to_binary(ocs:generate_identity()),
	IMSI = list_to_binary(ocs:generate_identity()),
	Subscriber = {MSISDN, IMSI},
	Password = ocs:generate_identity(),
	{ok, #service{}} = ocs:add_service(MSISDN, Password, ProdRef, []),
	Balance = rand:uniform(1000000000),
	B1 = bucket(octets, Balance),
	_BId = add_bucket(ProdRef, B1),
	Ref = erlang:ref_to_list(make_ref()),
   SId = diameter:session_id(Ref),
   RequestNum = 0,
	InputOctets = rand:uniform(Balance),
	OutputOctets = rand:uniform(Balance),
	RequestedServiceUnits = {InputOctets, OutputOctets},
   Answer0 = diameter_scur_start(SId, Subscriber, RequestNum, RequestedServiceUnits),
	#'3gpp_ro_CCA'{'Result-Code' = ?'DIAMETER_BASE_RESULT-CODE_SUCCESS',
			'Auth-Application-Id' = ?RO_APPLICATION_ID,
			'CC-Request-Type' = ?'3GPP_CC-REQUEST-TYPE_INITIAL_REQUEST',
			'CC-Request-Number' = RequestNum,
			'Multiple-Services-Credit-Control' = [MultiServices_CC]} = Answer0,
	#'3gpp_ro_Multiple-Services-Credit-Control'{
			'Granted-Service-Unit' = [GrantedUnits]} = MultiServices_CC,
	#'3gpp_ro_Granted-Service-Unit'{'CC-Total-Octets' = [_TotalOctets]} = GrantedUnits.

send_interim_scur() ->
	[{userdata, [{doc, "On received SCUR CCR-U send updateRating"}]}].

send_interim_scur(_Config) ->
	P1 = price(usage, octets, rand:uniform(10000000), rand:uniform(1000000)),
	OfferId = add_offer([P1], 4),
	ProdRef = add_product(OfferId),
	MSISDN = list_to_binary(ocs:generate_identity()),
	IMSI = list_to_binary(ocs:generate_identity()),
	Subscriber = {MSISDN, IMSI},
	Password = ocs:generate_identity(),
	{ok, #service{}} = ocs:add_service(MSISDN, Password, ProdRef, []),
	Balance = rand:uniform(1000000000),
	B1 = bucket(octets, Balance),
	_BId = add_bucket(ProdRef, B1),
	Ref = erlang:ref_to_list(make_ref()),
   SId = diameter:session_id(Ref),
   RequestNum0 = 0,
	InputOctets1 = rand:uniform(Balance),
	OutputOctets1 = rand:uniform(Balance),
	RequestedServiceUnits = {InputOctets1, OutputOctets1},
   Answer0 = diameter_scur_start(SId, Subscriber, RequestNum0, RequestedServiceUnits),
	#'3gpp_ro_CCA'{'Result-Code' = ?'DIAMETER_BASE_RESULT-CODE_SUCCESS'} = Answer0,
	RequestNum1 = RequestNum0 + 1,
	InputOctets2 = rand:uniform(Balance div 2),
	OutputOctets2 = rand:uniform(Balance),
	UsedServiceUnits = {InputOctets2, OutputOctets2},
	Answer1 = diameter_scur_interim(SId, Subscriber, RequestNum1, UsedServiceUnits, 0),
	#'3gpp_ro_CCA'{'Result-Code' = ?'DIAMETER_BASE_RESULT-CODE_SUCCESS'} = Answer1.

receive_interim_scur() ->
	[{userdata, [{doc, "On IEC updateRating response send CCA-U"}]}].

receive_interim_scur(_Config) ->
	P1 = price(usage, octets, rand:uniform(10000000), rand:uniform(1000000)),
	OfferId = add_offer([P1], 4),
	ProdRef = add_product(OfferId),
	MSISDN = list_to_binary(ocs:generate_identity()),
	IMSI = list_to_binary(ocs:generate_identity()),
	Subscriber = {MSISDN, IMSI},
	Password = ocs:generate_identity(),
	{ok, #service{}} = ocs:add_service(MSISDN, Password, ProdRef, []),
	Balance = rand:uniform(1000000000),
	B1 = bucket(octets, Balance),
	_BId = add_bucket(ProdRef, B1),
	Ref = erlang:ref_to_list(make_ref()),
   SId = diameter:session_id(Ref),
   RequestNum0 = 0,
	InputOctets1 = rand:uniform(Balance),
	OutputOctets1 = rand:uniform(Balance),
	RequestedServiceUnits = {InputOctets1, OutputOctets1},
   Answer0 = diameter_scur_start(SId, Subscriber, RequestNum0, RequestedServiceUnits),
	#'3gpp_ro_CCA'{'Result-Code' = ?'DIAMETER_BASE_RESULT-CODE_SUCCESS'} = Answer0,
   RequestNum1 = RequestNum0 + 1,
	InputOctets2 = rand:uniform(Balance div 2),
	OutputOctets2 = rand:uniform(Balance),
	UsedServiceUnits = {InputOctets2, OutputOctets2},
	Answer1 = diameter_scur_interim(SId, Subscriber, RequestNum1, UsedServiceUnits, 0),
	#'3gpp_ro_CCA'{'Result-Code' = ?'DIAMETER_BASE_RESULT-CODE_SUCCESS',
			'Auth-Application-Id' = ?RO_APPLICATION_ID,
			'CC-Request-Type' = ?'3GPP_CC-REQUEST-TYPE_UPDATE_REQUEST',
			'CC-Request-Number' = RequestNum1,
			'Multiple-Services-Credit-Control' = [MultiServices_CC]} = Answer1,
	#'3gpp_ro_Multiple-Services-Credit-Control'{
			'Used-Service-Unit' = [UsedUnits]} = MultiServices_CC,
	#'3gpp_ro_Used-Service-Unit'{'CC-Total-Octets' = [_TotalOctets]} = UsedUnits.

send_final_scur() ->
	[{userdata, [{doc, "On received SCUR CCR-U send endRating"}]}].

send_final_scur(_Config) ->
	P1 = price(usage, octets, rand:uniform(10000000), rand:uniform(1000000)),
	OfferId = add_offer([P1], 4),
	ProdRef = add_product(OfferId),
	MSISDN = list_to_binary(ocs:generate_identity()),
	IMSI = list_to_binary(ocs:generate_identity()),
	Subscriber = {MSISDN, IMSI},
	Password = ocs:generate_identity(),
	{ok, #service{}} = ocs:add_service(MSISDN, Password, ProdRef, []),
	Balance = rand:uniform(1000000000),
	B1 = bucket(octets, Balance),
	_BId = add_bucket(ProdRef, B1),
	Ref = erlang:ref_to_list(make_ref()),
	SId = diameter:session_id(Ref),
	RequestNum0 = 0,
	InputOctets1 = rand:uniform(Balance),
	OutputOctets1 = rand:uniform(Balance),
	RequestedServiceUnits = {InputOctets1, OutputOctets1},
   Answer0 = diameter_scur_start(SId, Subscriber, RequestNum0, RequestedServiceUnits),
	#'3gpp_ro_CCA'{'Result-Code' = ?'DIAMETER_BASE_RESULT-CODE_SUCCESS'} = Answer0,
	RequestNum1 = RequestNum0 + 1,
	InputOctets2 =  rand:uniform(Balance div 2),
	OutputOctets2 = rand:uniform(Balance),
	UsedServiceUnits = {InputOctets2, OutputOctets2},
	Answer1 = diameter_scur_interim(SId, Subscriber, RequestNum1, UsedServiceUnits, 0),
	#'3gpp_ro_CCA'{'Result-Code' = ?'DIAMETER_BASE_RESULT-CODE_SUCCESS'} = Answer1,
	RequestNum2 = RequestNum1 + 1,
	Grant2 = rand:uniform(Balance div 2),
	Answer2 = diameter_scur_stop(SId, Subscriber, RequestNum2, Grant2),
	#'3gpp_ro_CCA'{'Result-Code' = ?'DIAMETER_BASE_RESULT-CODE_SUCCESS'} = Answer2.

receive_final_scur() ->
	[{userdata, [{doc, "On IECendRatingresponse send CCA-U"}]}].

receive_final_scur(_Config) ->
	P1 = price(usage, octets, rand:uniform(10000000), rand:uniform(1000000)),
	OfferId = add_offer([P1], 4),
	ProdRef = add_product(OfferId),
	MSISDN = list_to_binary(ocs:generate_identity()),
	IMSI = list_to_binary(ocs:generate_identity()),
	Subscriber = {MSISDN, IMSI},
	Password = ocs:generate_identity(),
	{ok, #service{}} = ocs:add_service(MSISDN, Password, ProdRef, []),
	Balance = rand:uniform(1000000000),
	B1 = bucket(octets, Balance),
	_BId = add_bucket(ProdRef, B1),
	Ref = erlang:ref_to_list(make_ref()),
	SId = diameter:session_id(Ref),
	RequestNum0 = 0,
	InputOctets1 = rand:uniform(Balance),
	OutputOctets1 = rand:uniform(Balance),
	RequestedServiceUnits = {InputOctets1, OutputOctets1},
	Answer0 = diameter_scur_start(SId, Subscriber, RequestNum0, RequestedServiceUnits),
	#'3gpp_ro_CCA'{'Result-Code' = ?'DIAMETER_BASE_RESULT-CODE_SUCCESS'} = Answer0,
	RequestNum1 = RequestNum0 + 1,
	InputOctets2 = rand:uniform(Balance div 2),
	OutputOctets2 = rand:uniform(Balance),
	UsedServiceUnits = {InputOctets2, OutputOctets2},
	Answer1 = diameter_scur_interim(SId, Subscriber, RequestNum1, UsedServiceUnits, 0),
	#'3gpp_ro_CCA'{'Result-Code' = ?'DIAMETER_BASE_RESULT-CODE_SUCCESS'} = Answer1,
	RequestNum2 = RequestNum1 + 1,
	Grant2 = rand:uniform(Balance div 2),
	Answer2 = diameter_scur_stop(SId, Subscriber, RequestNum2, Grant2),
	#'3gpp_ro_CCA'{'Result-Code' = ?'DIAMETER_BASE_RESULT-CODE_SUCCESS',
			'Auth-Application-Id' = ?RO_APPLICATION_ID,
			'CC-Request-Type' = ?'3GPP_CC-REQUEST-TYPE_TERMINATION_REQUEST',
			'CC-Request-Number' = RequestNum2,
			'Multiple-Services-Credit-Control' = [MultiServices_CC]} = Answer2,
	#'3gpp_ro_Multiple-Services-Credit-Control'{
			'Used-Service-Unit' = [UsedUnits]} = MultiServices_CC,
	#'3gpp_ro_Used-Service-Unit'{'CC-Total-Octets' = [_TotalOctets]} = UsedUnits.

receive_interim_no_usu_scur() ->
	[{userdata, [{doc, "On IEC updateRating response with no USU send CCA-U"}]}].

receive_interim_no_usu_scur(_Config) ->
	P1 = price(usage, octets, rand:uniform(10000000), rand:uniform(1000000)),
	OfferId = add_offer([P1], 4),
	ProdRef = add_product(OfferId),
	MSISDN = list_to_binary(ocs:generate_identity()),
	IMSI = list_to_binary(ocs:generate_identity()),
	Subscriber = {MSISDN, IMSI},
	Password = ocs:generate_identity(),
	{ok, #service{}} = ocs:add_service(MSISDN, Password, ProdRef, []),
	Balance = rand:uniform(1000000000),
	B1 = bucket(octets, Balance),
	_BId = add_bucket(ProdRef, B1),
	Ref = erlang:ref_to_list(make_ref()),
   SId = diameter:session_id(Ref),
   RequestNum0 = 0,
	InputOctets1 = rand:uniform(Balance),
	OutputOctets1 = rand:uniform(Balance),
	RequestedServiceUnits1 = {InputOctets1, OutputOctets1},
   Answer0 = diameter_scur_start(SId, Subscriber, RequestNum0, RequestedServiceUnits1),
	#'3gpp_ro_CCA'{'Result-Code' = ?'DIAMETER_BASE_RESULT-CODE_SUCCESS'} = Answer0,
   RequestNum1 = RequestNum0 + 1,
	InputOctets2 = rand:uniform(Balance),
	OutputOctets2 = rand:uniform(Balance),
	RequestedServiceUnits2 = {InputOctets2, OutputOctets2},
	Answer1 = diameter_scur_interim1(SId, Subscriber, RequestNum1, 0, RequestedServiceUnits2),
	#'3gpp_ro_CCA'{'Result-Code' = ?'DIAMETER_BASE_RESULT-CODE_SUCCESS',
			'Auth-Application-Id' = ?RO_APPLICATION_ID,
			'CC-Request-Type' = ?'3GPP_CC-REQUEST-TYPE_UPDATE_REQUEST',
			'CC-Request-Number' = RequestNum1,
			'Multiple-Services-Credit-Control' = [MultiServices_CC]} = Answer1,
	#'3gpp_ro_Multiple-Services-Credit-Control'{
			'Granted-Service-Unit' = [GrantedUnits]} = MultiServices_CC,
	TotalGranted = InputOctets2 + OutputOctets2,
	#'3gpp_ro_Granted-Service-Unit'{'CC-Total-Octets' = [TotalGranted]} = GrantedUnits.

%%---------------------------------------------------------------------
%%  Internal functions
%%---------------------------------------------------------------------

diameter_scur_start(SId, {MSISDN, IMSI}, RequestNum, {InputOctets, OutputOctets}) ->
	MSISDN1 = #'3gpp_ro_Subscription-Id'{
			'Subscription-Id-Type' = ?'3GPP_SUBSCRIPTION-ID-TYPE_END_USER_E164',
			'Subscription-Id-Data' = MSISDN},
	IMSI1 = #'3gpp_ro_Subscription-Id'{
			'Subscription-Id-Type' = ?'3GPP_SUBSCRIPTION-ID-TYPE_END_USER_IMSI',
			'Subscription-Id-Data' = IMSI},
	RequestedUnits = #'3gpp_ro_Requested-Service-Unit' {
			'CC-Input-Octets' = [InputOctets], 'CC-Output-Octets' = [OutputOctets],
			'CC-Total-Octets' = [InputOctets + OutputOctets]},
	MultiServices_CC = #'3gpp_ro_Multiple-Services-Credit-Control'{
			'Requested-Service-Unit' = [RequestedUnits], 'Service-Identifier' = [1],
			'Rating-Group' = [2]},
	ServiceInformation = #'3gpp_ro_Service-Information'{'PS-Information' =
			[#'3gpp_ro_PS-Information'{
					'3GPP-PDP-Type' = [3],
					'Serving-Node-Type' = [2],
					'SGSN-Address' = [{10,1,2,3}],
					'GGSN-Address' = [{10,4,5,6}],
					'3GPP-IMSI-MCC-MNC' = [<<"001001">>],
					'3GPP-GGSN-MCC-MNC' = [<<"001001">>],
					'3GPP-SGSN-MCC-MNC' = [<<"001001">>]}]},
	CC_CCR = #'3gpp_ro_CCR'{'Session-Id' = SId,
			'Auth-Application-Id' = ?RO_APPLICATION_ID,
			'Service-Context-Id' = "32251@3gpp.org",
			'User-Name' = [MSISDN],
			'CC-Request-Type' = ?'3GPP_CC-REQUEST-TYPE_INITIAL_REQUEST',
			'CC-Request-Number' = RequestNum,
			'Event-Timestamp' = [calendar:universal_time()],
			'Subscription-Id' = [MSISDN1, IMSI1],
			'Multiple-Services-Credit-Control' = [MultiServices_CC],
			'Service-Information' = [ServiceInformation]},
	{ok, Answer} = diameter:call(?MODULE, cc_app_test, CC_CCR, []),
	Answer.

diameter_scur_interim(SId, {MSISDN, IMSI}, RequestNum,
		{UsedInputOctets, UsedOutputOctets}, _Requested) ->
	MSISDN1 = #'3gpp_ro_Subscription-Id'{
			'Subscription-Id-Type' = ?'3GPP_SUBSCRIPTION-ID-TYPE_END_USER_E164',
			'Subscription-Id-Data' = MSISDN},
	IMSI1 = #'3gpp_ro_Subscription-Id'{
			'Subscription-Id-Type' = ?'3GPP_SUBSCRIPTION-ID-TYPE_END_USER_IMSI',
			'Subscription-Id-Data' = IMSI},
	UsedUnits = #'3gpp_ro_Used-Service-Unit'{
			'CC-Input-Octets' = [UsedInputOctets], 'CC-Output-Octets' = [UsedOutputOctets],
			'CC-Total-Octets' = [UsedInputOctets + UsedOutputOctets]},
	RequestedUnits = #'3gpp_ro_Requested-Service-Unit' {
			'CC-Total-Octets' = []},
	MultiServices_CC = #'3gpp_ro_Multiple-Services-Credit-Control'{
			'Used-Service-Unit' = [UsedUnits],
			'Requested-Service-Unit' = [RequestedUnits], 'Service-Identifier' = [1],
			'Rating-Group' = [2]},
	ServiceInformation = #'3gpp_ro_Service-Information'{'PS-Information' =
			[#'3gpp_ro_PS-Information'{
					'3GPP-PDP-Type' = [3],
					'Serving-Node-Type' = [2],
					'SGSN-Address' = [{10,1,2,3}],
					'GGSN-Address' = [{10,4,5,6}],
					'3GPP-IMSI-MCC-MNC' = [<<"001001">>],
					'3GPP-GGSN-MCC-MNC' = [<<"001001">>],
					'3GPP-SGSN-MCC-MNC' = [<<"001001">>]}]},
	CC_CCR = #'3gpp_ro_CCR'{'Session-Id' = SId,
		'Auth-Application-Id' = ?RO_APPLICATION_ID,
		'Service-Context-Id' = "32251@3gpp.org" ,
		'User-Name' = [MSISDN],
		'CC-Request-Type' = ?'3GPP_CC-REQUEST-TYPE_UPDATE_REQUEST',
		'CC-Request-Number' = RequestNum,
		'Event-Timestamp' = [calendar:universal_time()],
		'Multiple-Services-Credit-Control' = [MultiServices_CC],
		'Subscription-Id' = [MSISDN1, IMSI1],
		'Service-Information' = [ServiceInformation]},
	{ok, Answer} = diameter:call(?MODULE, cc_app_test, CC_CCR, []),
	Answer.

diameter_scur_interim1(SId, {MSISDN, IMSI}, RequestNum, _Used, {InputOctets, OutputOctets}) ->
	MSISDN1 = #'3gpp_ro_Subscription-Id'{
			'Subscription-Id-Type' = ?'3GPP_SUBSCRIPTION-ID-TYPE_END_USER_E164',
			'Subscription-Id-Data' = MSISDN},
	IMSI1 = #'3gpp_ro_Subscription-Id'{
			'Subscription-Id-Type' = ?'3GPP_SUBSCRIPTION-ID-TYPE_END_USER_IMSI',
			'Subscription-Id-Data' = IMSI},
	UsedUnits = #'3gpp_ro_Used-Service-Unit'{
			'CC-Total-Octets' = []},
	RequestedUnits = #'3gpp_ro_Requested-Service-Unit' {
			'CC-Input-Octets' = [InputOctets], 'CC-Output-Octets' = [OutputOctets],
			'CC-Total-Octets' = [InputOctets + OutputOctets]},
	MultiServices_CC = #'3gpp_ro_Multiple-Services-Credit-Control'{
			'Used-Service-Unit' = [UsedUnits],
			'Requested-Service-Unit' = [RequestedUnits], 'Service-Identifier' = [1],
			'Rating-Group' = [2]},
	ServiceInformation = #'3gpp_ro_Service-Information'{'PS-Information' =
			[#'3gpp_ro_PS-Information'{
					'3GPP-PDP-Type' = [3],
					'Serving-Node-Type' = [2],
					'SGSN-Address' = [{10,1,2,3}],
					'GGSN-Address' = [{10,4,5,6}],
					'3GPP-IMSI-MCC-MNC' = [<<"001001">>],
					'3GPP-GGSN-MCC-MNC' = [<<"001001">>],
					'3GPP-SGSN-MCC-MNC' = [<<"001001">>]}]},
	CC_CCR = #'3gpp_ro_CCR'{'Session-Id' = SId,
		'Auth-Application-Id' = ?RO_APPLICATION_ID,
		'Service-Context-Id' = "32251@3gpp.org" ,
		'User-Name' = [MSISDN],
		'CC-Request-Type' = ?'3GPP_CC-REQUEST-TYPE_UPDATE_REQUEST',
		'CC-Request-Number' = RequestNum,
		'Event-Timestamp' = [calendar:universal_time()],
		'Multiple-Services-Credit-Control' = [MultiServices_CC],
		'Subscription-Id' = [MSISDN1, IMSI1],
		'Service-Information' = [ServiceInformation]},
	{ok, Answer} = diameter:call(?MODULE, cc_app_test, CC_CCR, []),
	Answer.

diameter_scur_stop(SId, {MSISDN, IMSI}, RequestNum, Used) ->
	MSISDN1 = #'3gpp_ro_Subscription-Id'{
			'Subscription-Id-Type' = ?'3GPP_SUBSCRIPTION-ID-TYPE_END_USER_E164',
			'Subscription-Id-Data' = MSISDN},
	IMSI1 = #'3gpp_ro_Subscription-Id'{
			'Subscription-Id-Type' = ?'3GPP_SUBSCRIPTION-ID-TYPE_END_USER_IMSI',
			'Subscription-Id-Data' = IMSI},
	UsedUnits = #'3gpp_ro_Used-Service-Unit'{'CC-Total-Octets' = [Used]},
	MultiServices_CC = #'3gpp_ro_Multiple-Services-Credit-Control'{
			'Used-Service-Unit' = [UsedUnits], 'Service-Identifier' = [1],
			'Rating-Group' = [2]},
	ServiceInformation = #'3gpp_ro_Service-Information'{'PS-Information' =
			[#'3gpp_ro_PS-Information'{
					'3GPP-PDP-Type' = [3],
					'Serving-Node-Type' = [2],
					'SGSN-Address' = [{10,1,2,3}],
					'GGSN-Address' = [{10,4,5,6}],
					'3GPP-IMSI-MCC-MNC' = [<<"001001">>],
					'3GPP-GGSN-MCC-MNC' = [<<"001001">>],
					'3GPP-SGSN-MCC-MNC' = [<<"001001">>]}]},
	CC_CCR = #'3gpp_ro_CCR'{'Session-Id' = SId,
			'Auth-Application-Id' = ?RO_APPLICATION_ID,
			'Service-Context-Id' = "32251@3gpp.org" ,
			'User-Name' = [MSISDN],
			'CC-Request-Type' = ?'3GPP_CC-REQUEST-TYPE_TERMINATION_REQUEST',
			'CC-Request-Number' = RequestNum,
			'Event-Timestamp' = [calendar:universal_time()],
			'Multiple-Services-Credit-Control' = [MultiServices_CC],
			'Subscription-Id' = [MSISDN1, IMSI1],
			'Service-Information' = [ServiceInformation]},
	{ok, Answer} = diameter:call(?MODULE, cc_app_test, CC_CCR, []),
	Answer.

%% @hidden
price(Type, Units, Size, Amount) ->
	#price{name = ocs:generate_identity(),
			type = Type, units = Units,
			size = Size, amount = Amount}.

%% @hidden
add_offer(Prices, Spec) when is_integer(Spec) ->
	add_offer(Prices, integer_to_list(Spec));
add_offer(Prices, Spec) ->
	Offer = #offer{name = ocs:generate_identity(),
			price = Prices, specification = Spec},
	{ok, #offer{name = OfferId}} = ocs:add_offer(Offer),
	OfferId.

%% @hidden
add_product(OfferId) ->
	add_product(OfferId, []).
add_product(OfferId, Chars) ->
	{ok, #product{id = ProdRef}} = ocs:add_product(OfferId, Chars),
	ProdRef.

%% @hidden
bucket(Units, RA) ->
	#bucket{units = Units, remain_amount = RA,
			start_date = erlang:system_time(?MILLISECOND),
			end_date = erlang:system_time(?MILLISECOND) + 2592000000}.

%% @hidden
add_bucket(ProdRef, Bucket) ->
	{ok, _, #bucket{id = BId}} = ocs:add_bucket(ProdRef, Bucket),
	BId.

%% @hidden
auth_header() ->
	{"authorization", basic_auth()}.

%% @hidden
basic_auth() ->
	RestUser = ct:get_config(rest_user),
	RestPass = ct:get_config(rest_pass),
	EncodeKey = base64:encode_to_string(string:concat(RestUser ++ ":", RestPass)),
	"Basic " ++ EncodeKey.

%% @doc Add a transport capability to diameter service.
%% @hidden
connect(SvcName, Address, Port, Transport) when is_atom(Transport) ->
	connect(SvcName, [{connect_timer, 30000} | transport_opts(Address, Port, Transport)]).

%% @hidden
connect(SvcName, Opts)->
	diameter:add_transport(SvcName, {connect, Opts}).

%% @hidden
client_acct_service_opts(Config) ->
	[{'Origin-Host', ?config(diameter_host, Config)},
			{'Origin-Realm', ?config(realm, Config)},
			{'Vendor-Id', ?IANA_PEN_SigScale},
			{'Supported-Vendor-Id', [?IANA_PEN_3GPP]},
			{'Product-Name', "SigScale Test Client (Nrf)"},
			{'Auth-Application-Id', [?RO_APPLICATION_ID]},
			{string_decode, false},
			{restrict_connections, false},
			{application, [{alias, base_app_test},
					{dictionary, diameter_gen_base_rfc6733},
					{module, diameter_test_client_cb}]},
        {application, [{alias, cc_app_test},
               {dictionary, diameter_gen_3gpp_ro_application},
               {module, diameter_test_client_cb}]}].

%% @hidden
transport_opts(Address, Port, Trans) when is_atom(Trans) ->
   transport_opts1({Trans, Address, Address, Port}).

%% @hidden
transport_opts1({Trans, LocalAddr, RemAddr, RemPort}) ->
	[{transport_module, Trans}, {transport_config,
		[{raddr, RemAddr}, {rport, RemPort},
		{reuseaddr, true}, {ip, LocalAddr}]}].

