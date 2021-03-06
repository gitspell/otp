%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 2007-2015. All Rights Reserved.
%%
%% The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved online at http://www.erlang.org/.
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%%
%% %CopyrightEnd%
%%

%%
%%----------------------------------------------------------------------
%% Purpose: Help functions for handling the SSL ciphers
%% 
%%----------------------------------------------------------------------

-module(ssl_cipher).

-include("ssl_internal.hrl").
-include("ssl_record.hrl").
-include("ssl_cipher.hrl").
-include("ssl_handshake.hrl").
-include("ssl_alert.hrl").
-include_lib("public_key/include/public_key.hrl").

-export([security_parameters/2, security_parameters/3, suite_definition/1,
	 decipher/6, cipher/5, suite/1, suites/1, all_suites/1, 
	 ec_keyed_suites/0, anonymous_suites/0, psk_suites/1, srp_suites/0,
	 openssl_suite/1, openssl_suite_name/1, filter/2, filter_suites/1,
	 hash_algorithm/1, sign_algorithm/1, is_acceptable_hash/2]).

-export_type([cipher_suite/0,
	      erl_cipher_suite/0, openssl_cipher_suite/0,
	      key_algo/0]).

-type cipher()            :: null |rc4_128 | idea_cbc | des40_cbc | des_cbc | '3des_ede_cbc' 
			   | aes_128_cbc |  aes_256_cbc.
-type hash()              :: null | sha | md5 | sha224 | sha256 | sha384 | sha512.
-type key_algo()          :: null | rsa | dhe_rsa | dhe_dss | ecdhe_ecdsa| ecdh_ecdsa | ecdh_rsa| srp_rsa| srp_dss | psk | dhe_psk | rsa_psk | dh_anon | ecdh_anon | srp_anon.
-type erl_cipher_suite()  :: {key_algo(), cipher(), hash()}.
-type int_cipher_suite()  :: {key_algo(), cipher(), hash(), hash() | default_prf}.
-type cipher_suite()      :: binary().
-type cipher_enum()        :: integer().
-type openssl_cipher_suite()  :: string().


-compile(inline).

%%--------------------------------------------------------------------
-spec security_parameters(cipher_suite(), #security_parameters{}) ->
				 #security_parameters{}.
%% Only security_parameters/2 should call security_parameters/3 with undefined as
%% first argument.
%%--------------------------------------------------------------------

security_parameters(?TLS_NULL_WITH_NULL_NULL = CipherSuite, SecParams) ->
    security_parameters(undefined, CipherSuite, SecParams).

%%--------------------------------------------------------------------
-spec security_parameters(ssl_record:ssl_version() | undefined, cipher_suite(), #security_parameters{}) ->
				 #security_parameters{}.
%%
%% Description: Returns a security parameters record where the
%% cipher values has been updated according to <CipherSuite> 
%%-------------------------------------------------------------------
security_parameters(Version, CipherSuite, SecParams) ->
    { _, Cipher, Hash, PrfHashAlg} = suite_definition(CipherSuite),
    SecParams#security_parameters{
      cipher_suite = CipherSuite,
      bulk_cipher_algorithm = bulk_cipher_algorithm(Cipher),
      cipher_type = type(Cipher),
      key_size = effective_key_bits(Cipher),
      expanded_key_material_length = expanded_key_material(Cipher),
      key_material_length = key_material(Cipher),
      iv_size = iv_size(Cipher),
      mac_algorithm = hash_algorithm(Hash),
      prf_algorithm = prf_algorithm(PrfHashAlg, Version),
      hash_size = hash_size(Hash)}.

%%--------------------------------------------------------------------
-spec cipher(cipher_enum(), #cipher_state{}, binary(), iodata(), ssl_record:ssl_version()) ->
		    {binary(), #cipher_state{}}. 
%%
%% Description: Encrypts the data and the MAC using chipher described
%% by cipher_enum() and updating the cipher state
%%-------------------------------------------------------------------
cipher(?NULL, CipherState, <<>>, Fragment, _Version) ->
    GenStreamCipherList = [Fragment, <<>>],
    {GenStreamCipherList, CipherState};
cipher(?RC4, CipherState, Mac, Fragment, _Version) ->
    State0 = case CipherState#cipher_state.state of
                 undefined -> crypto:stream_init(rc4, CipherState#cipher_state.key);
                 S -> S
             end,
    GenStreamCipherList = [Fragment, Mac],
    {State1, T} = crypto:stream_encrypt(State0, GenStreamCipherList),
    {T, CipherState#cipher_state{state = State1}};
cipher(?DES, CipherState, Mac, Fragment, Version) ->
    block_cipher(fun(Key, IV, T) ->
			 crypto:block_encrypt(des_cbc, Key, IV, T)
		 end, block_size(des_cbc), CipherState, Mac, Fragment, Version);
cipher(?'3DES', CipherState, Mac, Fragment, Version) ->
    block_cipher(fun(<<K1:8/binary, K2:8/binary, K3:8/binary>>, IV, T) ->
			 crypto:block_encrypt(des3_cbc, [K1, K2, K3], IV, T)
		 end, block_size(des_cbc), CipherState, Mac, Fragment, Version);
cipher(?AES, CipherState, Mac, Fragment, Version) ->
    block_cipher(fun(Key, IV, T) when byte_size(Key) =:= 16 ->
			 crypto:block_encrypt(aes_cbc128, Key, IV, T);
		    (Key, IV, T) when byte_size(Key) =:= 32 ->
			 crypto:block_encrypt(aes_cbc256, Key, IV, T)
		 end, block_size(aes_128_cbc), CipherState, Mac, Fragment, Version).

build_cipher_block(BlockSz, Mac, Fragment) ->
    TotSz = byte_size(Mac) + erlang:iolist_size(Fragment) + 1,
    {PaddingLength, Padding} = get_padding(TotSz, BlockSz),
    [Fragment, Mac, PaddingLength, Padding].

block_cipher(Fun, BlockSz, #cipher_state{key=Key, iv=IV} = CS0,
	     Mac, Fragment, {3, N})
  when N == 0; N == 1 ->
    L = build_cipher_block(BlockSz, Mac, Fragment),
    T = Fun(Key, IV, L),
    NextIV = next_iv(T, IV),
    {T, CS0#cipher_state{iv=NextIV}};

block_cipher(Fun, BlockSz, #cipher_state{key=Key, iv=IV} = CS0,
	     Mac, Fragment, {3, N})
  when N == 2; N == 3 ->
    NextIV = random_iv(IV),
    L0 = build_cipher_block(BlockSz, Mac, Fragment),
    L = [NextIV|L0],
    T = Fun(Key, IV, L),
    {T, CS0#cipher_state{iv=NextIV}}.

%%--------------------------------------------------------------------
-spec decipher(cipher_enum(), integer(), #cipher_state{}, binary(), 
	       ssl_record:ssl_version(), boolean()) ->
		      {binary(), binary(), #cipher_state{}} | #alert{}.
%%
%% Description: Decrypts the data and the MAC using cipher described
%% by cipher_enum() and updating the cipher state.
%%-------------------------------------------------------------------
decipher(?NULL, _HashSz, CipherState, Fragment, _, _) ->
    {Fragment, <<>>, CipherState};
decipher(?RC4, HashSz, CipherState, Fragment, _, _) ->
    State0 = case CipherState#cipher_state.state of
		 undefined -> crypto:stream_init(rc4, CipherState#cipher_state.key);
                 S -> S
             end,
    try crypto:stream_decrypt(State0, Fragment) of
	{State, Text} ->
	    GSC = generic_stream_cipher_from_bin(Text, HashSz),
	    #generic_stream_cipher{content = Content, mac = Mac} = GSC,
	    {Content, Mac, CipherState#cipher_state{state = State}}
    catch
	_:_ ->
	    %% This is a DECRYPTION_FAILED but
	    %% "differentiating between bad_record_mac and decryption_failed
	    %% alerts may permit certain attacks against CBC mode as used in
	    %% TLS [CBCATT].  It is preferable to uniformly use the
	    %% bad_record_mac alert to hide the specific type of the error."
	    ?ALERT_REC(?FATAL, ?BAD_RECORD_MAC)
    end;

decipher(?DES, HashSz, CipherState, Fragment, Version, PaddingCheck) ->
    block_decipher(fun(Key, IV, T) ->
			   crypto:block_decrypt(des_cbc, Key, IV, T)
		   end, CipherState, HashSz, Fragment, Version, PaddingCheck);
decipher(?'3DES', HashSz, CipherState, Fragment, Version, PaddingCheck) ->
    block_decipher(fun(<<K1:8/binary, K2:8/binary, K3:8/binary>>, IV, T) ->
			   crypto:block_decrypt(des3_cbc, [K1, K2, K3], IV, T)
		   end, CipherState, HashSz, Fragment, Version, PaddingCheck);
decipher(?AES, HashSz, CipherState, Fragment, Version, PaddingCheck) ->
    block_decipher(fun(Key, IV, T) when byte_size(Key) =:= 16 ->
			   crypto:block_decrypt(aes_cbc128, Key, IV, T);
		      (Key, IV, T) when byte_size(Key) =:= 32 ->
			   crypto:block_decrypt(aes_cbc256, Key, IV, T)
		   end, CipherState, HashSz, Fragment, Version, PaddingCheck).

block_decipher(Fun, #cipher_state{key=Key, iv=IV} = CipherState0, 
	       HashSz, Fragment, Version, PaddingCheck) ->
    try 
	Text = Fun(Key, IV, Fragment),
	NextIV = next_iv(Fragment, IV),
	GBC = generic_block_cipher_from_bin(Version, Text, NextIV, HashSz),
	Content = GBC#generic_block_cipher.content,
	Mac = GBC#generic_block_cipher.mac,
	CipherState1 = CipherState0#cipher_state{iv=GBC#generic_block_cipher.next_iv},
	case is_correct_padding(GBC, Version, PaddingCheck) of
	    true ->
		{Content, Mac, CipherState1};
	    false ->
		%% decryption failed or invalid padding,
		%% intentionally break Content to make
		%% sure a packet with invalid padding
		%% but otherwise correct data will fail
		%% the MAC test later
		{<<16#F0, Content/binary>>, Mac, CipherState1}
	end
    catch
	_:_ ->
	    %% This is a DECRYPTION_FAILED but
	    %% "differentiating between bad_record_mac and decryption_failed
	    %% alerts may permit certain attacks against CBC mode as used in
	    %% TLS [CBCATT].  It is preferable to uniformly use the
	    %% bad_record_mac alert to hide the specific type of the error."
	    ?ALERT_REC(?FATAL, ?BAD_RECORD_MAC)
    end.
%%--------------------------------------------------------------------
-spec suites(ssl_record:ssl_version()) -> [cipher_suite()].
%%
%% Description: Returns a list of supported cipher suites.
%%--------------------------------------------------------------------
suites({3, 0}) ->
    ssl_v3:suites();
suites({3, N}) ->
    tls_v1:suites(N).

all_suites(Version) ->
    suites(Version)
	++ ssl_cipher:anonymous_suites()
	++ ssl_cipher:psk_suites(Version)
	++ ssl_cipher:srp_suites().
%%--------------------------------------------------------------------
-spec anonymous_suites() -> [cipher_suite()].
%%
%% Description: Returns a list of the anonymous cipher suites, only supported
%% if explicitly set by user. Intended only for testing.
%%--------------------------------------------------------------------
anonymous_suites() ->
    [?TLS_DH_anon_WITH_RC4_128_MD5,
     ?TLS_DH_anon_WITH_DES_CBC_SHA,
     ?TLS_DH_anon_WITH_3DES_EDE_CBC_SHA,
     ?TLS_DH_anon_WITH_AES_128_CBC_SHA,
     ?TLS_DH_anon_WITH_AES_256_CBC_SHA,
     ?TLS_DH_anon_WITH_AES_128_CBC_SHA256,
     ?TLS_DH_anon_WITH_AES_256_CBC_SHA256,
     ?TLS_ECDH_anon_WITH_RC4_128_SHA,
     ?TLS_ECDH_anon_WITH_3DES_EDE_CBC_SHA,
     ?TLS_ECDH_anon_WITH_AES_128_CBC_SHA,
     ?TLS_ECDH_anon_WITH_AES_256_CBC_SHA].

%%--------------------------------------------------------------------
-spec psk_suites(ssl_record:ssl_version() | integer()) -> [cipher_suite()].
%%
%% Description: Returns a list of the PSK cipher suites, only supported
%% if explicitly set by user.
%%--------------------------------------------------------------------
psk_suites({3, N}) ->
    psk_suites(N);

psk_suites(N)
  when N >= 3 ->
    psk_suites(0) ++
	[?TLS_DHE_PSK_WITH_AES_256_CBC_SHA384,
	 ?TLS_RSA_PSK_WITH_AES_256_CBC_SHA384,
	 ?TLS_PSK_WITH_AES_256_CBC_SHA384,
	 ?TLS_DHE_PSK_WITH_AES_128_CBC_SHA256,
	 ?TLS_RSA_PSK_WITH_AES_128_CBC_SHA256,
	 ?TLS_PSK_WITH_AES_128_CBC_SHA256];

psk_suites(_) ->
	[?TLS_DHE_PSK_WITH_AES_256_CBC_SHA,
	 ?TLS_RSA_PSK_WITH_AES_256_CBC_SHA,
	 ?TLS_PSK_WITH_AES_256_CBC_SHA,
	 ?TLS_DHE_PSK_WITH_AES_128_CBC_SHA,
	 ?TLS_RSA_PSK_WITH_AES_128_CBC_SHA,
	 ?TLS_PSK_WITH_AES_128_CBC_SHA,
	 ?TLS_DHE_PSK_WITH_3DES_EDE_CBC_SHA,
	 ?TLS_RSA_PSK_WITH_3DES_EDE_CBC_SHA,
	 ?TLS_PSK_WITH_3DES_EDE_CBC_SHA,
	 ?TLS_DHE_PSK_WITH_RC4_128_SHA,
	 ?TLS_RSA_PSK_WITH_RC4_128_SHA,
	 ?TLS_PSK_WITH_RC4_128_SHA].

%%--------------------------------------------------------------------
-spec srp_suites() -> [cipher_suite()].
%%
%% Description: Returns a list of the SRP cipher suites, only supported
%% if explicitly set by user.
%%--------------------------------------------------------------------
srp_suites() ->
    [?TLS_SRP_SHA_WITH_3DES_EDE_CBC_SHA,
     ?TLS_SRP_SHA_RSA_WITH_3DES_EDE_CBC_SHA,
     ?TLS_SRP_SHA_DSS_WITH_3DES_EDE_CBC_SHA,
     ?TLS_SRP_SHA_WITH_AES_128_CBC_SHA,
     ?TLS_SRP_SHA_RSA_WITH_AES_128_CBC_SHA,
     ?TLS_SRP_SHA_DSS_WITH_AES_128_CBC_SHA,
     ?TLS_SRP_SHA_WITH_AES_256_CBC_SHA,
     ?TLS_SRP_SHA_RSA_WITH_AES_256_CBC_SHA,
     ?TLS_SRP_SHA_DSS_WITH_AES_256_CBC_SHA].

%%--------------------------------------------------------------------
-spec suite_definition(cipher_suite()) -> int_cipher_suite().
%%
%% Description: Return erlang cipher suite definition.
%% Note: Currently not supported suites are commented away.
%% They should be supported or removed in the future.
%%-------------------------------------------------------------------
%% TLS v1.1 suites
suite_definition(?TLS_NULL_WITH_NULL_NULL) ->
    {null, null, null, null};
%% RFC 5746 - Not a real cipher suite used to signal empty "renegotiation_info" extension
%% to avoid handshake failure from old servers that do not ignore
%% hello extension data as they should.
suite_definition(?TLS_EMPTY_RENEGOTIATION_INFO_SCSV) ->
    {null, null, null, null};
%% suite_definition(?TLS_RSA_WITH_NULL_MD5) ->
%%     {rsa, null, md5, default_prf};
%% suite_definition(?TLS_RSA_WITH_NULL_SHA) ->
%%     {rsa, null, sha, default_prf};
suite_definition(?TLS_RSA_WITH_RC4_128_MD5) ->	
    {rsa, rc4_128, md5, default_prf};
suite_definition(?TLS_RSA_WITH_RC4_128_SHA) ->
    {rsa, rc4_128, sha, default_prf};
suite_definition(?TLS_RSA_WITH_DES_CBC_SHA) ->
    {rsa, des_cbc, sha, default_prf};
suite_definition(?TLS_RSA_WITH_3DES_EDE_CBC_SHA) ->
    {rsa, '3des_ede_cbc', sha, default_prf};
suite_definition(?TLS_DHE_DSS_WITH_DES_CBC_SHA) ->
    {dhe_dss, des_cbc, sha, default_prf};
suite_definition(?TLS_DHE_DSS_WITH_3DES_EDE_CBC_SHA) ->
    {dhe_dss, '3des_ede_cbc', sha, default_prf};
suite_definition(?TLS_DHE_RSA_WITH_DES_CBC_SHA) ->
    {dhe_rsa, des_cbc, sha, default_prf};
suite_definition(?TLS_DHE_RSA_WITH_3DES_EDE_CBC_SHA) ->
    {dhe_rsa, '3des_ede_cbc', sha, default_prf};

%%% TSL V1.1 AES suites
suite_definition(?TLS_RSA_WITH_AES_128_CBC_SHA) -> 
    {rsa, aes_128_cbc, sha, default_prf};
suite_definition(?TLS_DHE_DSS_WITH_AES_128_CBC_SHA) ->
    {dhe_dss, aes_128_cbc, sha, default_prf};
suite_definition(?TLS_DHE_RSA_WITH_AES_128_CBC_SHA) ->
    {dhe_rsa, aes_128_cbc, sha, default_prf};
suite_definition(?TLS_RSA_WITH_AES_256_CBC_SHA) -> 
    {rsa, aes_256_cbc, sha, default_prf};
suite_definition(?TLS_DHE_DSS_WITH_AES_256_CBC_SHA) ->
    {dhe_dss, aes_256_cbc, sha, default_prf};
suite_definition(?TLS_DHE_RSA_WITH_AES_256_CBC_SHA) ->
    {dhe_rsa, aes_256_cbc, sha, default_prf};

%% TLS v1.2 suites

%% suite_definition(?TLS_RSA_WITH_NULL_SHA) ->
%%     {rsa, null, sha, default_prf};
suite_definition(?TLS_RSA_WITH_AES_128_CBC_SHA256) ->
    {rsa, aes_128_cbc, sha256, default_prf};
suite_definition(?TLS_RSA_WITH_AES_256_CBC_SHA256) ->
    {rsa, aes_256_cbc, sha256, default_prf};
suite_definition(?TLS_DHE_DSS_WITH_AES_128_CBC_SHA256) ->
    {dhe_dss, aes_128_cbc, sha256, default_prf};
suite_definition(?TLS_DHE_RSA_WITH_AES_128_CBC_SHA256) ->
    {dhe_rsa, aes_128_cbc, sha256, default_prf};
suite_definition(?TLS_DHE_DSS_WITH_AES_256_CBC_SHA256) ->
    {dhe_dss, aes_256_cbc, sha256, default_prf};
suite_definition(?TLS_DHE_RSA_WITH_AES_256_CBC_SHA256) ->
    {dhe_rsa, aes_256_cbc, sha256, default_prf};

%% not defined YET:
%%   TLS_DH_DSS_WITH_AES_128_CBC_SHA256      DH_DSS       AES_128_CBC  SHA256
%%   TLS_DH_RSA_WITH_AES_128_CBC_SHA256      DH_RSA       AES_128_CBC  SHA256
%%   TLS_DH_DSS_WITH_AES_256_CBC_SHA256      DH_DSS       AES_256_CBC  SHA256
%%   TLS_DH_RSA_WITH_AES_256_CBC_SHA256      DH_RSA       AES_256_CBC  SHA256

%%% DH-ANON deprecated by TLS spec and not available
%%% by default, but good for testing purposes.
suite_definition(?TLS_DH_anon_WITH_RC4_128_MD5) ->
    {dh_anon, rc4_128, md5, default_prf};
suite_definition(?TLS_DH_anon_WITH_DES_CBC_SHA) ->
    {dh_anon, des_cbc, sha, default_prf};
suite_definition(?TLS_DH_anon_WITH_3DES_EDE_CBC_SHA) ->
    {dh_anon, '3des_ede_cbc', sha, default_prf};
suite_definition(?TLS_DH_anon_WITH_AES_128_CBC_SHA) ->
    {dh_anon, aes_128_cbc, sha, default_prf};
suite_definition(?TLS_DH_anon_WITH_AES_256_CBC_SHA) ->
    {dh_anon, aes_256_cbc, sha, default_prf};
suite_definition(?TLS_DH_anon_WITH_AES_128_CBC_SHA256) ->
    {dh_anon, aes_128_cbc, sha256, default_prf};
suite_definition(?TLS_DH_anon_WITH_AES_256_CBC_SHA256) ->
    {dh_anon, aes_256_cbc, sha256, default_prf};

%%% PSK Cipher Suites RFC 4279

suite_definition(?TLS_PSK_WITH_RC4_128_SHA) ->
    {psk, rc4_128, sha, default_prf};
suite_definition(?TLS_PSK_WITH_3DES_EDE_CBC_SHA) ->
    {psk, '3des_ede_cbc', sha, default_prf};
suite_definition(?TLS_PSK_WITH_AES_128_CBC_SHA) ->
    {psk, aes_128_cbc, sha, default_prf};
suite_definition(?TLS_PSK_WITH_AES_256_CBC_SHA) ->
    {psk, aes_256_cbc, sha, default_prf};
suite_definition(?TLS_DHE_PSK_WITH_RC4_128_SHA) ->
    {dhe_psk, rc4_128, sha, default_prf};
suite_definition(?TLS_DHE_PSK_WITH_3DES_EDE_CBC_SHA) ->
    {dhe_psk, '3des_ede_cbc', sha, default_prf};
suite_definition(?TLS_DHE_PSK_WITH_AES_128_CBC_SHA) ->
    {dhe_psk, aes_128_cbc, sha, default_prf};
suite_definition(?TLS_DHE_PSK_WITH_AES_256_CBC_SHA) ->
    {dhe_psk, aes_256_cbc, sha, default_prf};
suite_definition(?TLS_RSA_PSK_WITH_RC4_128_SHA) ->
    {rsa_psk, rc4_128, sha, default_prf};
suite_definition(?TLS_RSA_PSK_WITH_3DES_EDE_CBC_SHA) ->
    {rsa_psk, '3des_ede_cbc', sha, default_prf};
suite_definition(?TLS_RSA_PSK_WITH_AES_128_CBC_SHA) ->
    {rsa_psk, aes_128_cbc, sha, default_prf};
suite_definition(?TLS_RSA_PSK_WITH_AES_256_CBC_SHA) ->
    {rsa_psk, aes_256_cbc, sha, default_prf};

%%% TLS 1.2 PSK Cipher Suites RFC 5487

suite_definition(?TLS_PSK_WITH_AES_128_CBC_SHA256) ->
    {psk, aes_128_cbc, sha256, default_prf};
suite_definition(?TLS_PSK_WITH_AES_256_CBC_SHA384) ->
    {psk, aes_256_cbc, sha384, default_prf};
suite_definition(?TLS_DHE_PSK_WITH_AES_128_CBC_SHA256) ->
    {dhe_psk, aes_128_cbc, sha256, default_prf};
suite_definition(?TLS_DHE_PSK_WITH_AES_256_CBC_SHA384) ->
    {dhe_psk, aes_256_cbc, sha384, default_prf};
suite_definition(?TLS_RSA_PSK_WITH_AES_128_CBC_SHA256) ->
    {rsa_psk, aes_128_cbc, sha256, default_prf};
suite_definition(?TLS_RSA_PSK_WITH_AES_256_CBC_SHA384) ->
    {rsa_psk, aes_256_cbc, sha384, default_prf};

suite_definition(?TLS_PSK_WITH_NULL_SHA256) ->
    {psk, null, sha256, default_prf};
suite_definition(?TLS_PSK_WITH_NULL_SHA384) ->
    {psk, null, sha384, default_prf};
suite_definition(?TLS_DHE_PSK_WITH_NULL_SHA256) ->
    {dhe_psk, null, sha256, default_prf};
suite_definition(?TLS_DHE_PSK_WITH_NULL_SHA384) ->
    {dhe_psk, null, sha384, default_prf};
suite_definition(?TLS_RSA_PSK_WITH_NULL_SHA256) ->
    {rsa_psk, null, sha256, default_prf};
suite_definition(?TLS_RSA_PSK_WITH_NULL_SHA384) ->
    {rsa_psk, null, sha384, default_prf};

%%% SRP Cipher Suites RFC 5054

suite_definition(?TLS_SRP_SHA_WITH_3DES_EDE_CBC_SHA) ->
    {srp_anon, '3des_ede_cbc', sha, default_prf};
suite_definition(?TLS_SRP_SHA_RSA_WITH_3DES_EDE_CBC_SHA) ->
    {srp_rsa, '3des_ede_cbc', sha, default_prf};
suite_definition(?TLS_SRP_SHA_DSS_WITH_3DES_EDE_CBC_SHA) ->
    {srp_dss, '3des_ede_cbc', sha, default_prf};
suite_definition(?TLS_SRP_SHA_WITH_AES_128_CBC_SHA) ->
    {srp_anon, aes_128_cbc, sha, default_prf};
suite_definition(?TLS_SRP_SHA_RSA_WITH_AES_128_CBC_SHA) ->
    {srp_rsa, aes_128_cbc, sha, default_prf};
suite_definition(?TLS_SRP_SHA_DSS_WITH_AES_128_CBC_SHA) ->
    {srp_dss, aes_128_cbc, sha, default_prf};
suite_definition(?TLS_SRP_SHA_WITH_AES_256_CBC_SHA) ->
    {srp_anon, aes_256_cbc, sha, default_prf};
suite_definition(?TLS_SRP_SHA_RSA_WITH_AES_256_CBC_SHA) ->
    {srp_rsa, aes_256_cbc, sha, default_prf};
suite_definition(?TLS_SRP_SHA_DSS_WITH_AES_256_CBC_SHA) ->
    {srp_dss, aes_256_cbc, sha, default_prf};

%% RFC 4492 EC TLS suites
suite_definition(?TLS_ECDH_ECDSA_WITH_NULL_SHA) ->
    {ecdh_ecdsa, null, sha, default_prf};
suite_definition(?TLS_ECDH_ECDSA_WITH_RC4_128_SHA) ->
    {ecdh_ecdsa, rc4_128, sha, default_prf};
suite_definition(?TLS_ECDH_ECDSA_WITH_3DES_EDE_CBC_SHA) ->
    {ecdh_ecdsa, '3des_ede_cbc', sha, default_prf};
suite_definition(?TLS_ECDH_ECDSA_WITH_AES_128_CBC_SHA) ->
    {ecdh_ecdsa, aes_128_cbc, sha, default_prf};
suite_definition(?TLS_ECDH_ECDSA_WITH_AES_256_CBC_SHA) ->
    {ecdh_ecdsa, aes_256_cbc, sha, default_prf};

suite_definition(?TLS_ECDHE_ECDSA_WITH_NULL_SHA) ->
    {ecdhe_ecdsa, null, sha, default_prf};
suite_definition(?TLS_ECDHE_ECDSA_WITH_RC4_128_SHA) ->
    {ecdhe_ecdsa, rc4_128, sha, default_prf};
suite_definition(?TLS_ECDHE_ECDSA_WITH_3DES_EDE_CBC_SHA) ->
    {ecdhe_ecdsa, '3des_ede_cbc', sha, default_prf};
suite_definition(?TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA) ->
    {ecdhe_ecdsa, aes_128_cbc, sha, default_prf};
suite_definition(?TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA) ->
    {ecdhe_ecdsa, aes_256_cbc, sha, default_prf};

suite_definition(?TLS_ECDH_RSA_WITH_NULL_SHA) ->
    {ecdh_rsa, null, sha, default_prf};
suite_definition(?TLS_ECDH_RSA_WITH_RC4_128_SHA) ->
    {ecdh_rsa, rc4_128, sha, default_prf};
suite_definition(?TLS_ECDH_RSA_WITH_3DES_EDE_CBC_SHA) ->
    {ecdh_rsa, '3des_ede_cbc', sha, default_prf};
suite_definition(?TLS_ECDH_RSA_WITH_AES_128_CBC_SHA) ->
    {ecdh_rsa, aes_128_cbc, sha, default_prf};
suite_definition(?TLS_ECDH_RSA_WITH_AES_256_CBC_SHA) ->
    {ecdh_rsa, aes_256_cbc, sha, default_prf};

suite_definition(?TLS_ECDHE_RSA_WITH_NULL_SHA) ->
    {ecdhe_rsa, null, sha, default_prf};
suite_definition(?TLS_ECDHE_RSA_WITH_RC4_128_SHA) ->
    {ecdhe_rsa, rc4_128, sha, default_prf};
suite_definition(?TLS_ECDHE_RSA_WITH_3DES_EDE_CBC_SHA) ->
    {ecdhe_rsa, '3des_ede_cbc', sha, default_prf};
suite_definition(?TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA) ->
    {ecdhe_rsa, aes_128_cbc, sha, default_prf};
suite_definition(?TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA) ->
    {ecdhe_rsa, aes_256_cbc, sha, default_prf};

suite_definition(?TLS_ECDH_anon_WITH_NULL_SHA) ->
    {ecdh_anon, null, sha, default_prf};
suite_definition(?TLS_ECDH_anon_WITH_RC4_128_SHA) ->
    {ecdh_anon, rc4_128, sha, default_prf};
suite_definition(?TLS_ECDH_anon_WITH_3DES_EDE_CBC_SHA) ->
    {ecdh_anon, '3des_ede_cbc', sha, default_prf};
suite_definition(?TLS_ECDH_anon_WITH_AES_128_CBC_SHA) ->
    {ecdh_anon, aes_128_cbc, sha, default_prf};
suite_definition(?TLS_ECDH_anon_WITH_AES_256_CBC_SHA) ->
    {ecdh_anon, aes_256_cbc, sha, default_prf};

%% RFC 5289 EC TLS suites
suite_definition(?TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256) ->
    {ecdhe_ecdsa, aes_128_cbc, sha256, sha256};
suite_definition(?TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA384) ->
    {ecdhe_ecdsa, aes_256_cbc, sha384, sha384};
suite_definition(?TLS_ECDH_ECDSA_WITH_AES_128_CBC_SHA256) ->
    {ecdh_ecdsa, aes_128_cbc, sha256, sha256};
suite_definition(?TLS_ECDH_ECDSA_WITH_AES_256_CBC_SHA384) ->
    {ecdh_ecdsa, aes_256_cbc, sha384, sha384};
suite_definition(?TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256) ->
    {ecdhe_rsa, aes_128_cbc, sha256, sha256};
suite_definition(?TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA384) ->
    {ecdhe_rsa, aes_256_cbc, sha384, sha384};
suite_definition(?TLS_ECDH_RSA_WITH_AES_128_CBC_SHA256) ->
    {ecdh_rsa, aes_128_cbc, sha256, sha256};
suite_definition(?TLS_ECDH_RSA_WITH_AES_256_CBC_SHA384) ->
    {ecdh_rsa, aes_256_cbc, sha384, sha384}.

%%--------------------------------------------------------------------
-spec suite(erl_cipher_suite()) -> cipher_suite().
%%
%% Description: Return TLS cipher suite definition.
%%--------------------------------------------------------------------

%% TLS v1.1 suites
%%suite({rsa, null, md5}) ->
%%    ?TLS_RSA_WITH_NULL_MD5;
%%suite({rsa, null, sha}) ->
%%    ?TLS_RSA_WITH_NULL_SHA;
suite({rsa, rc4_128, md5}) ->
    ?TLS_RSA_WITH_RC4_128_MD5;
suite({rsa, rc4_128, sha}) ->
    ?TLS_RSA_WITH_RC4_128_SHA;
suite({rsa, des_cbc, sha}) ->
    ?TLS_RSA_WITH_DES_CBC_SHA; 
suite({rsa, '3des_ede_cbc', sha}) ->
    ?TLS_RSA_WITH_3DES_EDE_CBC_SHA; 
suite({dhe_dss, des_cbc, sha}) ->
    ?TLS_DHE_DSS_WITH_DES_CBC_SHA;
suite({dhe_dss, '3des_ede_cbc', sha}) ->
    ?TLS_DHE_DSS_WITH_3DES_EDE_CBC_SHA;
suite({dhe_rsa, des_cbc, sha}) ->
    ?TLS_DHE_RSA_WITH_DES_CBC_SHA;
suite({dhe_rsa, '3des_ede_cbc', sha}) ->
    ?TLS_DHE_RSA_WITH_3DES_EDE_CBC_SHA; 
suite({dh_anon, rc4_128, md5}) ->
    ?TLS_DH_anon_WITH_RC4_128_MD5;
suite({dh_anon, des_cbc, sha}) ->
    ?TLS_DH_anon_WITH_DES_CBC_SHA;
suite({dh_anon, '3des_ede_cbc', sha}) ->
    ?TLS_DH_anon_WITH_3DES_EDE_CBC_SHA;

%%% TSL V1.1 AES suites
suite({rsa, aes_128_cbc, sha}) ->
    ?TLS_RSA_WITH_AES_128_CBC_SHA; 
suite({dhe_dss, aes_128_cbc, sha}) ->
    ?TLS_DHE_DSS_WITH_AES_128_CBC_SHA; 
suite({dhe_rsa, aes_128_cbc, sha}) ->
    ?TLS_DHE_RSA_WITH_AES_128_CBC_SHA;
suite({dh_anon, aes_128_cbc, sha}) ->
    ?TLS_DH_anon_WITH_AES_128_CBC_SHA;
suite({rsa, aes_256_cbc, sha}) ->
    ?TLS_RSA_WITH_AES_256_CBC_SHA;
suite({dhe_dss, aes_256_cbc, sha}) ->
    ?TLS_DHE_DSS_WITH_AES_256_CBC_SHA;
suite({dhe_rsa, aes_256_cbc, sha}) ->
    ?TLS_DHE_RSA_WITH_AES_256_CBC_SHA;
suite({dh_anon, aes_256_cbc, sha}) ->
    ?TLS_DH_anon_WITH_AES_256_CBC_SHA;

%% TLS v1.2 suites

%% suite_definition(?TLS_RSA_WITH_NULL_SHA) ->
%%     {rsa, null, sha, sha256};
suite({rsa, aes_128_cbc, sha256}) ->
    ?TLS_RSA_WITH_AES_128_CBC_SHA256;
suite({rsa, aes_256_cbc, sha256}) ->
    ?TLS_RSA_WITH_AES_256_CBC_SHA256;
suite({dhe_dss, aes_128_cbc, sha256}) ->
    ?TLS_DHE_DSS_WITH_AES_128_CBC_SHA256;
suite({dhe_rsa, aes_128_cbc, sha256}) ->
    ?TLS_DHE_RSA_WITH_AES_128_CBC_SHA256;
suite({dhe_dss, aes_256_cbc, sha256}) ->
    ?TLS_DHE_DSS_WITH_AES_256_CBC_SHA256;
suite({dhe_rsa, aes_256_cbc, sha256}) ->
    ?TLS_DHE_RSA_WITH_AES_256_CBC_SHA256;
suite({dh_anon, aes_128_cbc, sha256}) ->
    ?TLS_DH_anon_WITH_AES_128_CBC_SHA256;
suite({dh_anon, aes_256_cbc, sha256}) ->
    ?TLS_DH_anon_WITH_AES_256_CBC_SHA256;

%%% PSK Cipher Suites RFC 4279

suite({psk, rc4_128,sha}) ->
    ?TLS_PSK_WITH_RC4_128_SHA;
suite({psk, '3des_ede_cbc',sha}) ->
    ?TLS_PSK_WITH_3DES_EDE_CBC_SHA;
suite({psk, aes_128_cbc,sha}) ->
    ?TLS_PSK_WITH_AES_128_CBC_SHA;
suite({psk, aes_256_cbc,sha}) ->
    ?TLS_PSK_WITH_AES_256_CBC_SHA;
suite({dhe_psk, rc4_128,sha}) ->
    ?TLS_DHE_PSK_WITH_RC4_128_SHA;
suite({dhe_psk, '3des_ede_cbc',sha}) ->
    ?TLS_DHE_PSK_WITH_3DES_EDE_CBC_SHA;
suite({dhe_psk, aes_128_cbc,sha}) ->
    ?TLS_DHE_PSK_WITH_AES_128_CBC_SHA;
suite({dhe_psk, aes_256_cbc,sha}) ->
    ?TLS_DHE_PSK_WITH_AES_256_CBC_SHA;
suite({rsa_psk, rc4_128,sha}) ->
    ?TLS_RSA_PSK_WITH_RC4_128_SHA;
suite({rsa_psk, '3des_ede_cbc',sha}) ->
    ?TLS_RSA_PSK_WITH_3DES_EDE_CBC_SHA;
suite({rsa_psk, aes_128_cbc,sha}) ->
    ?TLS_RSA_PSK_WITH_AES_128_CBC_SHA;
suite({rsa_psk, aes_256_cbc,sha}) ->
    ?TLS_RSA_PSK_WITH_AES_256_CBC_SHA;

%%% TLS 1.2 PSK Cipher Suites RFC 5487

suite({psk, aes_128_cbc, sha256}) ->
    ?TLS_PSK_WITH_AES_128_CBC_SHA256;
suite({psk, aes_256_cbc, sha384}) ->
    ?TLS_PSK_WITH_AES_256_CBC_SHA384;
suite({dhe_psk, aes_128_cbc, sha256}) ->
    ?TLS_DHE_PSK_WITH_AES_128_CBC_SHA256;
suite({dhe_psk, aes_256_cbc, sha384}) ->
    ?TLS_DHE_PSK_WITH_AES_256_CBC_SHA384;
suite({rsa_psk, aes_128_cbc, sha256}) ->
    ?TLS_RSA_PSK_WITH_AES_128_CBC_SHA256;
suite({rsa_psk, aes_256_cbc, sha384}) ->
    ?TLS_RSA_PSK_WITH_AES_256_CBC_SHA384;

suite({psk, null, sha256}) ->
    ?TLS_PSK_WITH_NULL_SHA256;
suite({psk, null, sha384}) ->
    ?TLS_PSK_WITH_NULL_SHA384;
suite({dhe_psk, null, sha256}) ->
    ?TLS_DHE_PSK_WITH_NULL_SHA256;
suite({dhe_psk, null, sha384}) ->
    ?TLS_DHE_PSK_WITH_NULL_SHA384;
suite({rsa_psk, null, sha256}) ->
    ?TLS_RSA_PSK_WITH_NULL_SHA256;
suite({rsa_psk, null, sha384}) ->
    ?TLS_RSA_PSK_WITH_NULL_SHA384;

%%% SRP Cipher Suites RFC 5054

suite({srp_anon, '3des_ede_cbc', sha}) ->
    ?TLS_SRP_SHA_WITH_3DES_EDE_CBC_SHA;
suite({srp_rsa, '3des_ede_cbc', sha}) ->
    ?TLS_SRP_SHA_RSA_WITH_3DES_EDE_CBC_SHA;
suite({srp_dss, '3des_ede_cbc', sha}) ->
    ?TLS_SRP_SHA_DSS_WITH_3DES_EDE_CBC_SHA;
suite({srp_anon, aes_128_cbc, sha}) ->
    ?TLS_SRP_SHA_WITH_AES_128_CBC_SHA;
suite({srp_rsa, aes_128_cbc, sha}) ->
    ?TLS_SRP_SHA_RSA_WITH_AES_128_CBC_SHA;
suite({srp_dss, aes_128_cbc, sha}) ->
    ?TLS_SRP_SHA_DSS_WITH_AES_128_CBC_SHA;
suite({srp_anon, aes_256_cbc, sha}) ->
    ?TLS_SRP_SHA_WITH_AES_256_CBC_SHA;
suite({srp_rsa, aes_256_cbc, sha}) ->
    ?TLS_SRP_SHA_RSA_WITH_AES_256_CBC_SHA;
suite({srp_dss, aes_256_cbc, sha}) ->
    ?TLS_SRP_SHA_DSS_WITH_AES_256_CBC_SHA;

%%% RFC 4492 EC TLS suites
suite({ecdh_ecdsa, null, sha}) ->
    ?TLS_ECDH_ECDSA_WITH_NULL_SHA;
suite({ecdh_ecdsa, rc4_128, sha}) ->
    ?TLS_ECDH_ECDSA_WITH_RC4_128_SHA;
suite({ecdh_ecdsa, '3des_ede_cbc', sha}) ->
    ?TLS_ECDH_ECDSA_WITH_3DES_EDE_CBC_SHA;
suite({ecdh_ecdsa, aes_128_cbc, sha}) ->
    ?TLS_ECDH_ECDSA_WITH_AES_128_CBC_SHA;
suite({ecdh_ecdsa, aes_256_cbc, sha}) ->
    ?TLS_ECDH_ECDSA_WITH_AES_256_CBC_SHA;

suite({ecdhe_ecdsa, null, sha}) ->
    ?TLS_ECDHE_ECDSA_WITH_NULL_SHA;
suite({ecdhe_ecdsa, rc4_128, sha}) ->
    ?TLS_ECDHE_ECDSA_WITH_RC4_128_SHA;
suite({ecdhe_ecdsa, '3des_ede_cbc', sha}) ->
    ?TLS_ECDHE_ECDSA_WITH_3DES_EDE_CBC_SHA;
suite({ecdhe_ecdsa, aes_128_cbc, sha}) ->
    ?TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA;
suite({ecdhe_ecdsa, aes_256_cbc, sha}) ->
    ?TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA;

suite({ecdh_rsa, null, sha}) ->
    ?TLS_ECDH_RSA_WITH_NULL_SHA;
suite({ecdh_rsa, rc4_128, sha}) ->
    ?TLS_ECDH_RSA_WITH_RC4_128_SHA;
suite({ecdh_rsa, '3des_ede_cbc', sha}) ->
    ?TLS_ECDH_RSA_WITH_3DES_EDE_CBC_SHA;
suite({ecdh_rsa, aes_128_cbc, sha}) ->
    ?TLS_ECDH_RSA_WITH_AES_128_CBC_SHA;
suite({ecdh_rsa, aes_256_cbc, sha}) ->
    ?TLS_ECDH_RSA_WITH_AES_256_CBC_SHA;

suite({ecdhe_rsa, null, sha}) ->
    ?TLS_ECDHE_RSA_WITH_NULL_SHA;
suite({ecdhe_rsa, rc4_128, sha}) ->
    ?TLS_ECDHE_RSA_WITH_RC4_128_SHA;
suite({ecdhe_rsa, '3des_ede_cbc', sha}) ->
    ?TLS_ECDHE_RSA_WITH_3DES_EDE_CBC_SHA;
suite({ecdhe_rsa, aes_128_cbc, sha}) ->
    ?TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA;
suite({ecdhe_rsa, aes_256_cbc, sha}) ->
    ?TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA;

suite({ecdh_anon, null, sha}) ->
    ?TLS_ECDH_anon_WITH_NULL_SHA;
suite({ecdh_anon, rc4_128, sha}) ->
    ?TLS_ECDH_anon_WITH_RC4_128_SHA;
suite({ecdh_anon, '3des_ede_cbc', sha}) ->
    ?TLS_ECDH_anon_WITH_3DES_EDE_CBC_SHA;
suite({ecdh_anon, aes_128_cbc, sha}) ->
    ?TLS_ECDH_anon_WITH_AES_128_CBC_SHA;
suite({ecdh_anon, aes_256_cbc, sha}) ->
    ?TLS_ECDH_anon_WITH_AES_256_CBC_SHA;

%%% RFC 5289 EC TLS suites
suite({ecdhe_ecdsa, aes_128_cbc, sha256}) ->
    ?TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256;
suite({ecdhe_ecdsa, aes_256_cbc, sha384}) ->
    ?TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA384;
suite({ecdh_ecdsa, aes_128_cbc, sha256}) ->
    ?TLS_ECDH_ECDSA_WITH_AES_128_CBC_SHA256;
suite({ecdh_ecdsa, aes_256_cbc, sha384}) ->
    ?TLS_ECDH_ECDSA_WITH_AES_256_CBC_SHA384;
suite({ecdhe_rsa, aes_128_cbc, sha256}) ->
    ?TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256;
suite({ecdhe_rsa, aes_256_cbc, sha384}) ->
    ?TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA384;
suite({ecdh_rsa, aes_128_cbc, sha256}) ->
    ?TLS_ECDH_RSA_WITH_AES_128_CBC_SHA256;
suite({ecdh_rsa, aes_256_cbc, sha384}) ->
    ?TLS_ECDH_RSA_WITH_AES_256_CBC_SHA384.

%%--------------------------------------------------------------------
-spec openssl_suite(openssl_cipher_suite()) -> cipher_suite().
%%
%% Description: Return TLS cipher suite definition.
%%--------------------------------------------------------------------
%% translate constants <-> openssl-strings
openssl_suite("DHE-RSA-AES256-SHA256") ->
    ?TLS_DHE_RSA_WITH_AES_256_CBC_SHA256;
openssl_suite("DHE-DSS-AES256-SHA256") ->
    ?TLS_DHE_DSS_WITH_AES_256_CBC_SHA256;
openssl_suite("AES256-SHA256") ->
    ?TLS_RSA_WITH_AES_256_CBC_SHA256;
openssl_suite("DHE-RSA-AES128-SHA256") ->
    ?TLS_DHE_RSA_WITH_AES_128_CBC_SHA256;
openssl_suite("DHE-DSS-AES128-SHA256") ->
    ?TLS_DHE_DSS_WITH_AES_128_CBC_SHA256;
openssl_suite("AES128-SHA256") ->
    ?TLS_RSA_WITH_AES_128_CBC_SHA256;
openssl_suite("DHE-RSA-AES256-SHA") ->
    ?TLS_DHE_RSA_WITH_AES_256_CBC_SHA;
openssl_suite("DHE-DSS-AES256-SHA") ->
    ?TLS_DHE_DSS_WITH_AES_256_CBC_SHA;
openssl_suite("AES256-SHA") ->
    ?TLS_RSA_WITH_AES_256_CBC_SHA;
openssl_suite("EDH-RSA-DES-CBC3-SHA") ->
    ?TLS_DHE_RSA_WITH_3DES_EDE_CBC_SHA;
openssl_suite("EDH-DSS-DES-CBC3-SHA") ->
    ?TLS_DHE_DSS_WITH_3DES_EDE_CBC_SHA;
openssl_suite("DES-CBC3-SHA") ->
    ?TLS_RSA_WITH_3DES_EDE_CBC_SHA;
openssl_suite("DHE-RSA-AES128-SHA") ->
    ?TLS_DHE_RSA_WITH_AES_128_CBC_SHA;
openssl_suite("DHE-DSS-AES128-SHA") ->
    ?TLS_DHE_DSS_WITH_AES_128_CBC_SHA;
openssl_suite("AES128-SHA") ->
    ?TLS_RSA_WITH_AES_128_CBC_SHA;
openssl_suite("RC4-SHA") ->
    ?TLS_RSA_WITH_RC4_128_SHA;
openssl_suite("RC4-MD5") -> 
    ?TLS_RSA_WITH_RC4_128_MD5;
openssl_suite("EDH-RSA-DES-CBC-SHA") ->
    ?TLS_DHE_RSA_WITH_DES_CBC_SHA;
openssl_suite("DES-CBC-SHA") ->
    ?TLS_RSA_WITH_DES_CBC_SHA;

%%% SRP Cipher Suites RFC 5054

openssl_suite("SRP-DSS-AES-256-CBC-SHA") ->
    ?TLS_SRP_SHA_DSS_WITH_AES_256_CBC_SHA;
openssl_suite("SRP-RSA-AES-256-CBC-SHA") ->
    ?TLS_SRP_SHA_RSA_WITH_AES_256_CBC_SHA;
openssl_suite("SRP-DSS-3DES-EDE-CBC-SHA") ->
    ?TLS_SRP_SHA_DSS_WITH_3DES_EDE_CBC_SHA;
openssl_suite("SRP-RSA-3DES-EDE-CBC-SHA") ->
    ?TLS_SRP_SHA_RSA_WITH_3DES_EDE_CBC_SHA;
openssl_suite("SRP-DSS-AES-128-CBC-SHA") ->
    ?TLS_SRP_SHA_DSS_WITH_AES_128_CBC_SHA;
openssl_suite("SRP-RSA-AES-128-CBC-SHA") ->
    ?TLS_SRP_SHA_RSA_WITH_AES_128_CBC_SHA;

%% RFC 4492 EC TLS suites
openssl_suite("ECDH-ECDSA-RC4-SHA") ->
    ?TLS_ECDH_ECDSA_WITH_RC4_128_SHA;
openssl_suite("ECDH-ECDSA-DES-CBC3-SHA") ->
    ?TLS_ECDH_ECDSA_WITH_3DES_EDE_CBC_SHA;
openssl_suite("ECDH-ECDSA-AES128-SHA") ->
    ?TLS_ECDH_ECDSA_WITH_AES_128_CBC_SHA;
openssl_suite("ECDH-ECDSA-AES256-SHA") ->
    ?TLS_ECDH_ECDSA_WITH_AES_256_CBC_SHA;

openssl_suite("ECDHE-ECDSA-RC4-SHA") ->
    ?TLS_ECDHE_ECDSA_WITH_RC4_128_SHA;
openssl_suite("ECDHE-ECDSA-DES-CBC3-SHA") ->
    ?TLS_ECDHE_ECDSA_WITH_3DES_EDE_CBC_SHA;
openssl_suite("ECDHE-ECDSA-AES128-SHA") ->
    ?TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA;
openssl_suite("ECDHE-ECDSA-AES256-SHA") ->
    ?TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA;

openssl_suite("ECDHE-RSA-RC4-SHA") ->
    ?TLS_ECDHE_RSA_WITH_RC4_128_SHA;
openssl_suite("ECDHE-RSA-DES-CBC3-SHA") ->
    ?TLS_ECDHE_RSA_WITH_3DES_EDE_CBC_SHA;
openssl_suite("ECDHE-RSA-AES128-SHA") ->
    ?TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA;
openssl_suite("ECDHE-RSA-AES256-SHA") ->
    ?TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA;

openssl_suite("ECDH-RSA-RC4-SHA") ->
    ?TLS_ECDH_RSA_WITH_RC4_128_SHA;
openssl_suite("ECDH-RSA-DES-CBC3-SHA") ->
    ?TLS_ECDH_RSA_WITH_3DES_EDE_CBC_SHA;
openssl_suite("ECDH-RSA-AES128-SHA") ->
    ?TLS_ECDH_RSA_WITH_AES_128_CBC_SHA;
openssl_suite("ECDH-RSA-AES256-SHA") ->
    ?TLS_ECDH_RSA_WITH_AES_256_CBC_SHA;

%% RFC 5289 EC TLS suites
openssl_suite("ECDHE-ECDSA-AES128-SHA256") ->
    ?TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256;
openssl_suite("ECDHE-ECDSA-AES256-SHA384") ->
    ?TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA384;
openssl_suite("ECDH-ECDSA-AES128-SHA256") ->
    ?TLS_ECDH_ECDSA_WITH_AES_128_CBC_SHA256;
openssl_suite("ECDH-ECDSA-AES256-SHA384") ->
    ?TLS_ECDH_ECDSA_WITH_AES_256_CBC_SHA384;
openssl_suite("ECDHE-RSA-AES128-SHA256") ->
    ?TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256;
openssl_suite("ECDHE-RSA-AES256-SHA384") ->
    ?TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA384;
openssl_suite("ECDH-RSA-AES128-SHA256") ->
    ?TLS_ECDH_RSA_WITH_AES_128_CBC_SHA256;
openssl_suite("ECDH-RSA-AES256-SHA384") ->
    ?TLS_ECDH_RSA_WITH_AES_256_CBC_SHA384.

%%--------------------------------------------------------------------
-spec openssl_suite_name(cipher_suite()) -> openssl_cipher_suite().
%%
%% Description: Return openssl cipher suite name.
%%-------------------------------------------------------------------
openssl_suite_name(?TLS_DHE_RSA_WITH_AES_256_CBC_SHA) ->
    "DHE-RSA-AES256-SHA";
openssl_suite_name(?TLS_DHE_DSS_WITH_AES_256_CBC_SHA) ->
    "DHE-DSS-AES256-SHA";
openssl_suite_name(?TLS_RSA_WITH_AES_256_CBC_SHA) ->
    "AES256-SHA";
openssl_suite_name(?TLS_DHE_RSA_WITH_3DES_EDE_CBC_SHA) ->
    "EDH-RSA-DES-CBC3-SHA";
openssl_suite_name(?TLS_DHE_DSS_WITH_3DES_EDE_CBC_SHA) ->
    "EDH-DSS-DES-CBC3-SHA";
openssl_suite_name(?TLS_RSA_WITH_3DES_EDE_CBC_SHA) ->
    "DES-CBC3-SHA";
openssl_suite_name( ?TLS_DHE_RSA_WITH_AES_128_CBC_SHA) ->
    "DHE-RSA-AES128-SHA";
openssl_suite_name(?TLS_DHE_DSS_WITH_AES_128_CBC_SHA) ->
    "DHE-DSS-AES128-SHA";
openssl_suite_name(?TLS_RSA_WITH_AES_128_CBC_SHA) ->
    "AES128-SHA";
openssl_suite_name(?TLS_RSA_WITH_RC4_128_SHA) ->
    "RC4-SHA";
openssl_suite_name(?TLS_RSA_WITH_RC4_128_MD5) -> 
    "RC4-MD5";
openssl_suite_name(?TLS_DHE_RSA_WITH_DES_CBC_SHA) ->
    "EDH-RSA-DES-CBC-SHA";
openssl_suite_name(?TLS_RSA_WITH_DES_CBC_SHA) ->
    "DES-CBC-SHA";
openssl_suite_name(?TLS_RSA_WITH_NULL_SHA256) ->
    "NULL-SHA256";
openssl_suite_name(?TLS_RSA_WITH_AES_128_CBC_SHA256) ->
    "AES128-SHA256";
openssl_suite_name(?TLS_RSA_WITH_AES_256_CBC_SHA256) ->
    "AES256-SHA256";
openssl_suite_name(?TLS_DH_DSS_WITH_AES_128_CBC_SHA256) ->
    "DH-DSS-AES128-SHA256";
openssl_suite_name(?TLS_DH_RSA_WITH_AES_128_CBC_SHA256) ->
    "DH-RSA-AES128-SHA256";
openssl_suite_name(?TLS_DHE_DSS_WITH_AES_128_CBC_SHA256) ->
    "DHE-DSS-AES128-SHA256";
openssl_suite_name(?TLS_DHE_RSA_WITH_AES_128_CBC_SHA256) ->
    "DHE-RSA-AES128-SHA256";
openssl_suite_name(?TLS_DH_DSS_WITH_AES_256_CBC_SHA256) ->
    "DH-DSS-AES256-SHA256";
openssl_suite_name(?TLS_DH_RSA_WITH_AES_256_CBC_SHA256) ->
    "DH-RSA-AES256-SHA256";
openssl_suite_name(?TLS_DHE_DSS_WITH_AES_256_CBC_SHA256) ->
    "DHE-DSS-AES256-SHA256";
openssl_suite_name(?TLS_DHE_RSA_WITH_AES_256_CBC_SHA256) ->
    "DHE-RSA-AES256-SHA256";

%%% PSK Cipher Suites RFC 4279

openssl_suite_name(?TLS_PSK_WITH_AES_256_CBC_SHA) ->
    "PSK-AES256-CBC-SHA";
openssl_suite_name(?TLS_PSK_WITH_3DES_EDE_CBC_SHA) ->
    "PSK-3DES-EDE-CBC-SHA";
openssl_suite_name(?TLS_PSK_WITH_AES_128_CBC_SHA) ->
    "PSK-AES128-CBC-SHA";
openssl_suite_name(?TLS_PSK_WITH_RC4_128_SHA) ->
    "PSK-RC4-SHA";

%%% SRP Cipher Suites RFC 5054

openssl_suite_name(?TLS_SRP_SHA_RSA_WITH_3DES_EDE_CBC_SHA) ->
    "SRP-RSA-3DES-EDE-CBC-SHA";
openssl_suite_name(?TLS_SRP_SHA_DSS_WITH_3DES_EDE_CBC_SHA) ->
    "SRP-DSS-3DES-EDE-CBC-SHA";
openssl_suite_name(?TLS_SRP_SHA_RSA_WITH_AES_128_CBC_SHA) ->
    "SRP-RSA-AES-128-CBC-SHA";
openssl_suite_name(?TLS_SRP_SHA_DSS_WITH_AES_128_CBC_SHA) ->
    "SRP-DSS-AES-128-CBC-SHA";
openssl_suite_name(?TLS_SRP_SHA_RSA_WITH_AES_256_CBC_SHA) ->
    "SRP-RSA-AES-256-CBC-SHA";
openssl_suite_name(?TLS_SRP_SHA_DSS_WITH_AES_256_CBC_SHA) ->
    "SRP-DSS-AES-256-CBC-SHA";

%% RFC 4492 EC TLS suites
openssl_suite_name(?TLS_ECDH_ECDSA_WITH_RC4_128_SHA) ->
    "ECDH-ECDSA-RC4-SHA";
openssl_suite_name(?TLS_ECDH_ECDSA_WITH_3DES_EDE_CBC_SHA) ->
    "ECDH-ECDSA-DES-CBC3-SHA";
openssl_suite_name(?TLS_ECDH_ECDSA_WITH_AES_128_CBC_SHA) ->
    "ECDH-ECDSA-AES128-SHA";
openssl_suite_name(?TLS_ECDH_ECDSA_WITH_AES_256_CBC_SHA) ->
    "ECDH-ECDSA-AES256-SHA";

openssl_suite_name(?TLS_ECDHE_ECDSA_WITH_RC4_128_SHA) ->
    "ECDHE-ECDSA-RC4-SHA";
openssl_suite_name(?TLS_ECDHE_ECDSA_WITH_3DES_EDE_CBC_SHA) ->
    "ECDHE-ECDSA-DES-CBC3-SHA";
openssl_suite_name(?TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA) ->
    "ECDHE-ECDSA-AES128-SHA";
openssl_suite_name(?TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA) ->
    "ECDHE-ECDSA-AES256-SHA";

openssl_suite_name(?TLS_ECDH_RSA_WITH_RC4_128_SHA) ->
    "ECDH-RSA-RC4-SHA";
openssl_suite_name(?TLS_ECDH_RSA_WITH_3DES_EDE_CBC_SHA) ->
    "ECDH-RSA-DES-CBC3-SHA";
openssl_suite_name(?TLS_ECDH_RSA_WITH_AES_128_CBC_SHA) ->
    "ECDH-RSA-AES128-SHA";
openssl_suite_name(?TLS_ECDH_RSA_WITH_AES_256_CBC_SHA) ->
    "ECDH-RSA-AES256-SHA";

openssl_suite_name(?TLS_ECDHE_RSA_WITH_RC4_128_SHA) ->
    "ECDHE-RSA-RC4-SHA";
openssl_suite_name(?TLS_ECDHE_RSA_WITH_3DES_EDE_CBC_SHA) ->
    "ECDHE-RSA-DES-CBC3-SHA";
openssl_suite_name(?TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA) ->
    "ECDHE-RSA-AES128-SHA";
openssl_suite_name(?TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA) ->
    "ECDHE-RSA-AES256-SHA";

%% RFC 5289 EC TLS suites
openssl_suite_name(?TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256) ->
    "ECDHE-ECDSA-AES128-SHA256";
openssl_suite_name(?TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA384) ->
    "ECDHE-ECDSA-AES256-SHA384";
openssl_suite_name(?TLS_ECDH_ECDSA_WITH_AES_128_CBC_SHA256) ->
    "ECDH-ECDSA-AES128-SHA256";
openssl_suite_name(?TLS_ECDH_ECDSA_WITH_AES_256_CBC_SHA384) ->
    "ECDH-ECDSA-AES256-SHA384";
openssl_suite_name(?TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256) ->
    "ECDHE-RSA-AES128-SHA256";
openssl_suite_name(?TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA384) ->
    "ECDHE-RSA-AES256-SHA384";
openssl_suite_name(?TLS_ECDH_RSA_WITH_AES_128_CBC_SHA256) ->
    "ECDH-RSA-AES128-SHA256";
openssl_suite_name(?TLS_ECDH_RSA_WITH_AES_256_CBC_SHA384) ->
    "ECDH-RSA-AES256-SHA384";

%% No oppenssl name
openssl_suite_name(Cipher) ->
    suite_definition(Cipher).

%%--------------------------------------------------------------------
-spec filter(undefined | binary(), [cipher_suite()]) -> [cipher_suite()].
%%
%% Description: Select the cipher suites that can be used together with the 
%% supplied certificate. (Server side functionality)  
%%-------------------------------------------------------------------
filter(undefined, Ciphers) -> 
    Ciphers;
filter(DerCert, Ciphers) ->
    OtpCert = public_key:pkix_decode_cert(DerCert, otp),
    SigAlg = OtpCert#'OTPCertificate'.signatureAlgorithm,
    PubKeyInfo = OtpCert#'OTPCertificate'.tbsCertificate#'OTPTBSCertificate'.subjectPublicKeyInfo,
    PubKeyAlg = PubKeyInfo#'OTPSubjectPublicKeyInfo'.algorithm,

    Ciphers1 =
	case ssl_certificate:public_key_type(PubKeyAlg#'PublicKeyAlgorithm'.algorithm) of
	    rsa ->
		filter_keyuse(OtpCert, ((Ciphers -- dsa_signed_suites()) -- ec_keyed_suites()) -- ecdh_suites(),
			      rsa_suites(), dhe_rsa_suites() ++ ecdhe_rsa_suites());
	    dsa ->
		(Ciphers -- rsa_keyed_suites()) -- ec_keyed_suites();
	    ec ->
		filter_keyuse(OtpCert, (Ciphers -- rsa_keyed_suites()) -- dsa_signed_suites(),
			      [], ecdhe_ecdsa_suites())
	end,

    case public_key:pkix_sign_types(SigAlg#'SignatureAlgorithm'.algorithm) of
	{_, rsa} ->
	    Ciphers1 -- ecdsa_signed_suites();
	{_, dsa} ->
	    Ciphers1;
	{_, ecdsa} ->
	    Ciphers1 -- rsa_signed_suites()
    end.
	
%%--------------------------------------------------------------------
-spec filter_suites([cipher_suite()]) -> [cipher_suite()].
%%
%% Description: Filter suites for algorithms supported by crypto.
%%-------------------------------------------------------------------
filter_suites(Suites = [{_,_,_}|_]) ->
    Algos = crypto:supports(),
    lists:filter(fun({KeyExchange, Cipher, Hash}) ->
			 is_acceptable_keyexchange(KeyExchange,  proplists:get_value(public_keys, Algos)) andalso
			     is_acceptable_cipher(Cipher,  proplists:get_value(ciphers, Algos)) andalso
			     is_acceptable_hash(Hash,  proplists:get_value(hashs, Algos))
		 end, Suites);

filter_suites(Suites = [{_,_,_,_}|_]) ->
    Algos = crypto:supports(),
    Hashs =  proplists:get_value(hashs, Algos),
    lists:filter(fun({KeyExchange, Cipher, Hash, Prf}) ->
			 is_acceptable_keyexchange(KeyExchange, proplists:get_value(public_keys, Algos)) andalso
			     is_acceptable_cipher(Cipher, proplists:get_value(ciphers, Algos)) andalso
			     is_acceptable_hash(Hash, Hashs) andalso
			     is_acceptable_prf(Prf, Hashs)
		 end, Suites);

filter_suites(Suites) ->
    Algos = crypto:supports(),
    Hashs =  proplists:get_value(hashs, Algos),
    lists:filter(fun(Suite) ->
			 {KeyExchange, Cipher, Hash, Prf} = ssl_cipher:suite_definition(Suite),
			 is_acceptable_keyexchange(KeyExchange, proplists:get_value(public_keys, Algos)) andalso
			     is_acceptable_cipher(Cipher,  proplists:get_value(ciphers, Algos)) andalso
			     is_acceptable_hash(Hash, Hashs) andalso
			     is_acceptable_prf(Prf, Hashs)
		 end, Suites).

is_acceptable_keyexchange(KeyExchange, Algos)
  when KeyExchange == ecdh_ecdsa;
       KeyExchange == ecdhe_ecdsa;
       KeyExchange == ecdh_rsa;
       KeyExchange == ecdhe_rsa;
       KeyExchange == ecdh_anon ->
    proplists:get_bool(ecdh, Algos);
is_acceptable_keyexchange(_, _) ->
    true.

is_acceptable_cipher(_, _) ->
    true.

is_acceptable_hash(null, _Algos) ->
    true;
is_acceptable_hash(Hash, Algos) ->
    proplists:get_bool(Hash, Algos).

is_acceptable_prf(default_prf, _) ->
    true;
is_acceptable_prf(Prf, Algos) ->
    proplists:get_bool(Prf, Algos).

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

bulk_cipher_algorithm(null) ->
    ?NULL;
bulk_cipher_algorithm(rc4_128) ->
    ?RC4;
bulk_cipher_algorithm(des_cbc) ->
    ?DES;
bulk_cipher_algorithm('3des_ede_cbc') ->
    ?'3DES';
bulk_cipher_algorithm(Cipher) when Cipher == aes_128_cbc;
				   Cipher == aes_256_cbc ->
    ?AES.

type(Cipher) when Cipher == null;
		  Cipher == rc4_128 ->
    ?STREAM;

type(Cipher) when Cipher == des_cbc;
		  Cipher == '3des_ede_cbc';
		  Cipher == aes_128_cbc;
		  Cipher == aes_256_cbc ->
    ?BLOCK.

key_material(null) ->
    0;
key_material(rc4_128) ->
    16;
key_material(des_cbc) ->
    8;
key_material('3des_ede_cbc') ->
    24;
key_material(aes_128_cbc) ->
    16;
key_material(aes_256_cbc) ->
    32.

expanded_key_material(null) ->
    0;
expanded_key_material(rc4_128) ->
    16;
expanded_key_material(Cipher) when Cipher == des_cbc ->
    8;
expanded_key_material('3des_ede_cbc') ->
    24;
expanded_key_material(Cipher) when Cipher == aes_128_cbc;
 				   Cipher == aes_256_cbc ->
    unknown.  


effective_key_bits(null) ->
    0;
effective_key_bits(des_cbc) ->
    56;
effective_key_bits(Cipher) when Cipher == rc4_128;
				Cipher == aes_128_cbc ->
    128;
effective_key_bits('3des_ede_cbc') ->
    168;
effective_key_bits(aes_256_cbc) ->
    256.

iv_size(Cipher) when Cipher == null;
		     Cipher == rc4_128 ->
    0;
iv_size(Cipher) ->
    block_size(Cipher).

block_size(Cipher) when Cipher == des_cbc;
			Cipher == '3des_ede_cbc' -> 
    8;

block_size(Cipher) when Cipher == aes_128_cbc;
			Cipher == aes_256_cbc ->
    16.

prf_algorithm(default_prf, {3, N}) when N >= 3 ->
    ?SHA256;
prf_algorithm(default_prf, {3, _}) ->
    ?MD5SHA;
prf_algorithm(Algo, _) ->
    hash_algorithm(Algo).

hash_algorithm(null)   -> ?NULL;
hash_algorithm(md5)    -> ?MD5;
hash_algorithm(sha)   -> ?SHA; %% Only sha always refers to "SHA-1"
hash_algorithm(sha224) -> ?SHA224;
hash_algorithm(sha256) -> ?SHA256;
hash_algorithm(sha384) -> ?SHA384;
hash_algorithm(sha512) -> ?SHA512;
hash_algorithm(?NULL) -> null;
hash_algorithm(?MD5) -> md5;
hash_algorithm(?SHA) -> sha;
hash_algorithm(?SHA224) -> sha224;
hash_algorithm(?SHA256) -> sha256;
hash_algorithm(?SHA384) -> sha384;
hash_algorithm(?SHA512) -> sha512.

sign_algorithm(anon)  -> ?ANON;
sign_algorithm(rsa)   -> ?RSA;
sign_algorithm(dsa)   -> ?DSA;
sign_algorithm(ecdsa) -> ?ECDSA;
sign_algorithm(?ANON) -> anon;
sign_algorithm(?RSA) -> rsa;
sign_algorithm(?DSA) -> dsa;
sign_algorithm(?ECDSA) -> ecdsa.

hash_size(null) ->
    0;
hash_size(md5) ->
    16;
hash_size(sha) ->
    20;
%% Uncomment when adding cipher suite that needs it
%hash_size(sha224) ->
%    28;
hash_size(sha256) ->
    32;
hash_size(sha384) ->
    48.
%% Uncomment when adding cipher suite that needs it
%hash_size(sha512) ->
%    64.

%% RFC 5246: 6.2.3.2.  CBC Block Cipher
%%
%%   Implementation note: Canvel et al. [CBCTIME] have demonstrated a
%%   timing attack on CBC padding based on the time required to compute
%%   the MAC.  In order to defend against this attack, implementations
%%   MUST ensure that record processing time is essentially the same
%%   whether or not the padding is correct.  In general, the best way to
%%   do this is to compute the MAC even if the padding is incorrect, and
%%   only then reject the packet.  For instance, if the pad appears to be
%%   incorrect, the implementation might assume a zero-length pad and then
%%   compute the MAC.  This leaves a small timing channel, since MAC
%%   performance depends to some extent on the size of the data fragment,
%%   but it is not believed to be large enough to be exploitable, due to
%%   the large block size of existing MACs and the small size of the
%%   timing signal.
%%
%% implementation note:
%%   We return the original (possibly invalid) PadLength in any case.
%%   An invalid PadLength will be caught by is_correct_padding/2
%%
generic_block_cipher_from_bin({3, N}, T, IV, HashSize)
  when N == 0; N == 1 ->
    Sz1 = byte_size(T) - 1,
    <<_:Sz1/binary, ?BYTE(PadLength0)>> = T,
    PadLength = if
		    PadLength0 >= Sz1 -> 0;
		    true -> PadLength0
		end,
    CompressedLength = byte_size(T) - PadLength - 1 - HashSize,
    <<Content:CompressedLength/binary, Mac:HashSize/binary,
     Padding:PadLength/binary, ?BYTE(PadLength0)>> = T,
    #generic_block_cipher{content=Content, mac=Mac,
			  padding=Padding, padding_length=PadLength0,
			  next_iv = IV};

generic_block_cipher_from_bin({3, N}, T, IV, HashSize)
  when N == 2; N == 3 ->
    Sz1 = byte_size(T) - 1,
    <<_:Sz1/binary, ?BYTE(PadLength)>> = T,
    IVLength = byte_size(IV),
    CompressedLength = byte_size(T) - IVLength - PadLength - 1 - HashSize,
    <<NextIV:IVLength/binary, Content:CompressedLength/binary, Mac:HashSize/binary,
      Padding:PadLength/binary, ?BYTE(PadLength)>> = T,
    #generic_block_cipher{content=Content, mac=Mac,
			  padding=Padding, padding_length=PadLength,
			  next_iv = NextIV}.

generic_stream_cipher_from_bin(T, HashSz) ->
    Sz = byte_size(T),
    CompressedLength = Sz - HashSz,
    <<Content:CompressedLength/binary, Mac:HashSz/binary>> = T,
    #generic_stream_cipher{content=Content,
			   mac=Mac}.

is_correct_padding(#generic_block_cipher{padding_length = Len,
					 padding = Padding}, {3, 0}, _) ->
    Len == byte_size(Padding); %% Only length check is done in SSL 3.0 spec
%% For interoperability reasons it is possible to disable
%% the padding check when using TLS 1.0, as it is not strictly required 
%% in the spec (only recommended), howerver this makes TLS 1.0 vunrable to the Poodle attack 
%% so by default this clause will not match
is_correct_padding(GenBlockCipher, {3, 1}, false) ->
    is_correct_padding(GenBlockCipher, {3, 0}, false);
%% Padding must be checked in TLS 1.1 and after  
is_correct_padding(#generic_block_cipher{padding_length = Len,
					 padding = Padding}, _, _) ->
    Len == byte_size(Padding) andalso
		list_to_binary(lists:duplicate(Len, Len)) == Padding.

get_padding(Length, BlockSize) ->
    get_padding_aux(BlockSize, Length rem BlockSize).

get_padding_aux(_, 0) ->
    {0, <<>>};
get_padding_aux(BlockSize, PadLength) ->
    N = BlockSize - PadLength,
    {N, list_to_binary(lists:duplicate(N, N))}.

random_iv(IV) ->
    IVSz = byte_size(IV),
    ssl:random_bytes(IVSz).

next_iv(Bin, IV) ->
    BinSz = byte_size(Bin),
    IVSz = byte_size(IV),
    FirstPart = BinSz - IVSz,
    <<_:FirstPart/binary, NextIV:IVSz/binary>> = Bin,
    NextIV.

rsa_signed_suites() ->
    dhe_rsa_suites() ++ rsa_suites() ++
	psk_rsa_suites() ++ srp_rsa_suites() ++
	ecdh_rsa_suites() ++ ecdhe_rsa_suites().

rsa_keyed_suites() ->
    dhe_rsa_suites() ++ rsa_suites() ++
	psk_rsa_suites() ++ srp_rsa_suites() ++
	ecdhe_rsa_suites().

dhe_rsa_suites() ->
    [?TLS_DHE_RSA_WITH_AES_256_CBC_SHA256,
     ?TLS_DHE_RSA_WITH_AES_256_CBC_SHA,
     ?TLS_DHE_RSA_WITH_3DES_EDE_CBC_SHA,
     ?TLS_DHE_RSA_WITH_AES_128_CBC_SHA256,
     ?TLS_DHE_RSA_WITH_AES_128_CBC_SHA,
     ?TLS_DHE_RSA_WITH_DES_CBC_SHA].

psk_rsa_suites() ->
    [?TLS_RSA_PSK_WITH_AES_256_CBC_SHA384,
     ?TLS_RSA_PSK_WITH_AES_128_CBC_SHA256,
     ?TLS_RSA_PSK_WITH_AES_256_CBC_SHA,
     ?TLS_RSA_PSK_WITH_AES_128_CBC_SHA,
     ?TLS_RSA_PSK_WITH_3DES_EDE_CBC_SHA,
     ?TLS_RSA_PSK_WITH_RC4_128_SHA].

srp_rsa_suites() ->
    [?TLS_SRP_SHA_RSA_WITH_3DES_EDE_CBC_SHA,
     ?TLS_SRP_SHA_RSA_WITH_AES_128_CBC_SHA,
     ?TLS_SRP_SHA_RSA_WITH_AES_256_CBC_SHA].

rsa_suites() ->
    [?TLS_RSA_WITH_AES_256_CBC_SHA256,
     ?TLS_RSA_WITH_AES_256_CBC_SHA,
     ?TLS_RSA_WITH_3DES_EDE_CBC_SHA,
     ?TLS_RSA_WITH_AES_128_CBC_SHA256,
     ?TLS_RSA_WITH_AES_128_CBC_SHA,
     ?TLS_RSA_WITH_RC4_128_SHA,
     ?TLS_RSA_WITH_RC4_128_MD5,
     ?TLS_RSA_WITH_DES_CBC_SHA].

ecdh_rsa_suites() ->
    [?TLS_ECDH_RSA_WITH_NULL_SHA,
     ?TLS_ECDH_RSA_WITH_RC4_128_SHA,
     ?TLS_ECDH_RSA_WITH_3DES_EDE_CBC_SHA,
     ?TLS_ECDH_RSA_WITH_AES_128_CBC_SHA,
     ?TLS_ECDH_RSA_WITH_AES_256_CBC_SHA,
     ?TLS_ECDH_RSA_WITH_AES_128_CBC_SHA256,
     ?TLS_ECDH_RSA_WITH_AES_256_CBC_SHA384].

ecdhe_rsa_suites() ->
    [?TLS_ECDHE_RSA_WITH_NULL_SHA,
     ?TLS_ECDHE_RSA_WITH_RC4_128_SHA,
     ?TLS_ECDHE_RSA_WITH_3DES_EDE_CBC_SHA,
     ?TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA,
     ?TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA,
     ?TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256,
     ?TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA384].

dsa_signed_suites() ->
    dhe_dss_suites() ++ srp_dss_suites().

dhe_dss_suites()  ->
    [?TLS_DHE_DSS_WITH_AES_256_CBC_SHA256,
     ?TLS_DHE_DSS_WITH_AES_256_CBC_SHA,
     ?TLS_DHE_DSS_WITH_3DES_EDE_CBC_SHA,
     ?TLS_DHE_DSS_WITH_AES_128_CBC_SHA256,
     ?TLS_DHE_DSS_WITH_AES_128_CBC_SHA,
     ?TLS_DHE_DSS_WITH_3DES_EDE_CBC_SHA].

srp_dss_suites() ->
    [?TLS_SRP_SHA_DSS_WITH_3DES_EDE_CBC_SHA,
     ?TLS_SRP_SHA_DSS_WITH_AES_128_CBC_SHA,
     ?TLS_SRP_SHA_DSS_WITH_AES_256_CBC_SHA].

ec_keyed_suites() ->
    ecdh_ecdsa_suites() ++ ecdhe_ecdsa_suites()
	++ ecdh_rsa_suites().

ecdsa_signed_suites() ->
    ecdh_ecdsa_suites() ++ ecdhe_ecdsa_suites().

ecdh_suites() ->
    ecdh_rsa_suites() ++ ecdh_ecdsa_suites().

ecdh_ecdsa_suites() ->
    [?TLS_ECDH_ECDSA_WITH_NULL_SHA,
     ?TLS_ECDH_ECDSA_WITH_RC4_128_SHA,
     ?TLS_ECDH_ECDSA_WITH_3DES_EDE_CBC_SHA,
     ?TLS_ECDH_ECDSA_WITH_AES_128_CBC_SHA,
     ?TLS_ECDH_ECDSA_WITH_AES_256_CBC_SHA,
     ?TLS_ECDH_ECDSA_WITH_AES_128_CBC_SHA256,
     ?TLS_ECDH_ECDSA_WITH_AES_256_CBC_SHA384].

ecdhe_ecdsa_suites() ->
    [?TLS_ECDHE_ECDSA_WITH_NULL_SHA,
     ?TLS_ECDHE_ECDSA_WITH_RC4_128_SHA,
     ?TLS_ECDHE_ECDSA_WITH_3DES_EDE_CBC_SHA,
     ?TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA,
     ?TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA,
     ?TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256,
     ?TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA384].

filter_keyuse(OtpCert, Ciphers, Suites, SignSuites) ->
    TBSCert = OtpCert#'OTPCertificate'.tbsCertificate, 
    TBSExtensions = TBSCert#'OTPTBSCertificate'.extensions,
    Extensions = ssl_certificate:extensions_list(TBSExtensions),
    case ssl_certificate:select_extension(?'id-ce-keyUsage', Extensions) of
	undefined ->
	    Ciphers;
	#'Extension'{extnValue = KeyUse} ->
	    Result = filter_keyuse_suites(keyEncipherment,
					  KeyUse, Ciphers, Suites),
	    filter_keyuse_suites(digitalSignature,
				 KeyUse, Result, SignSuites)
    end.

filter_keyuse_suites(Use, KeyUse, CipherSuits, Suites) ->
    case ssl_certificate:is_valid_key_usage(KeyUse, Use) of
	true ->
	    CipherSuits;
	false ->
	    CipherSuits -- Suites
    end.
