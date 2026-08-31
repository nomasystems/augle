%%%-------------------------------------------------------------------
%%% @author Tristan Sloughter <t@crashfast.com>
%%% @copyright (C) 2017, Tristan Sloughter
%%% @doc
%%%
%%% @end
%%% Created : 4 Sep 2017 by Tristan Sloughter <t@crashfast.com>
%%%-------------------------------------------------------------------
-module(augle_jwt).

-export([assertion/3]).

-include_lib("public_key/include/public_key.hrl").

-define(JWT_HEADER, #{alg => <<"RS256">>, typ => <<"JWT">>}).
-define(TOKEN_LIFETIME, 3600).

%% @doc Builds the signed RS256 JWT that Google exchanges for an access token.
-spec assertion(unicode:unicode_binary(), unicode:unicode_binary(), binary()) -> binary().
assertion(Iss, Scopes, EncodedPrivateKey) ->
    [PemEntry] = public_key:pem_decode(EncodedPrivateKey),
    PrivateKey = asn1_decode(public_key:pem_entry_decode(PemEntry)),

    EncodedJWTHeader = encode(?JWT_HEADER),
    EncodedJWTClaimSet = encode(claim_set(Iss, Scopes)),
    Signature = compute_signature(EncodedJWTHeader, EncodedJWTClaimSet, PrivateKey),

    <<EncodedJWTHeader/binary, ".", EncodedJWTClaimSet/binary, ".", Signature/binary>>.

%%

asn1_decode(#'PrivateKeyInfo'{privateKey=DerKey}) ->
    public_key:der_decode('RSAPrivateKey', DerKey);
asn1_decode(Der) ->
    Der.

claim_set(Iss, Scopes) ->
    Now = erlang:system_time(second),
    #{iss => Iss,
      scope => Scopes,
      aud => augle_conf:auth_url(),
      exp => Now + ?TOKEN_LIFETIME,
      iat => Now}.

encode(Json) ->
    %% json:encode/1 returns a deep iolist, which base64:encode/2 does not take
    base64url(iolist_to_binary(json:encode(Json))).

base64url(Data) ->
    base64:encode(Data, #{mode => urlsafe, padding => false}).

compute_signature(Header, ClaimSet, #'RSAPrivateKey'{publicExponent=Exponent
                                                    ,modulus=Modulus
                                                    ,privateExponent=PrivateExponent}) ->
    base64url(crypto:sign(rsa, sha256, <<Header/binary, ".", ClaimSet/binary>>,
                          [Exponent, Modulus, PrivateExponent])).
