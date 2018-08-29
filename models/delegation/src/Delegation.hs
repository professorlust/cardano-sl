{-# LANGUAGE PackageImports #-}
{-# LANGUAGE FlexibleInstances #-}

module Delegation where

import           Crypto.Hash           (Digest, SHA256, hash)
import qualified Data.ByteArray        as BA
import qualified Data.ByteString.Char8 as BS
import           Data.Foldable         (all)
import           Data.List             (find)
import           Data.Map              (Map)
import qualified Data.Map              as Map
import           Data.Maybe            (isJust)
import           Data.Monoid           (Monoid)
import           Data.Semigroup        (Semigroup, (<>))
import           Data.Set              (Set)
import qualified Data.Set              as Set


newtype TxId = TxId { getTxId :: Digest SHA256 }
  deriving (Show, Eq, Ord)
data Addr = AddrTxin (Digest SHA256) (Digest SHA256)
          | AddrAccount (Digest SHA256) (Digest SHA256)
          deriving (Show, Eq, Ord)
newtype Coin = Coin Int deriving (Show, Eq, Ord)
data Cert = RegKey | DeRegKey | Delegate | RegPool | RetirePool
  deriving (Show, Eq, Ord)

newtype Owner = Owner Int deriving (Show, Eq, Ord)
newtype SKey = SKey Owner deriving (Show, Eq, Ord)
newtype VKey = VKey Owner deriving (Show, Eq, Ord)
newtype HashKey = HashKey (Digest SHA256) deriving (Show, Eq, Ord)
data Sig a = Sig a Owner deriving (Show, Eq, Ord)
data WitTxin = WitTxin VKey (Sig TxBody) deriving (Show, Eq, Ord)
data WitCert = WitCert VKey (Sig TxBody) deriving (Show, Eq, Ord)
data Wits = Wits { txinWits :: (Set WitTxin)
                 , certWits :: (Set WitCert)
                 } deriving (Show, Eq, Ord)

data TxIn = TxIn TxId Int deriving (Show, Eq, Ord)
data TxOut = TxOut Addr Coin deriving (Show, Eq, Ord)
data TxBody = TxBody { inputs  :: Set TxIn
                     , outputs :: [TxOut]
                     , certs   :: Set Cert
                     } deriving (Show, Eq, Ord)
data Tx = Tx { body :: TxBody
             , wits :: Wits
             } deriving (Show, Eq)

newtype UTxO = UTxO (Map TxIn TxOut) deriving (Show, Eq, Ord)

-- TODO is it okay that I've used list indices instead of implementing the Ix Type?

instance BA.ByteArrayAccess Tx where
  length        = BA.length . BS.pack . show
  withByteArray = BA.withByteArray . BS.pack  . show

instance BA.ByteArrayAccess VKey where
  length        = BA.length . BS.pack . show
  withByteArray = BA.withByteArray . BS.pack . show

instance BA.ByteArrayAccess SKey where
  length        = BA.length . BS.pack . show
  withByteArray = BA.withByteArray . BS.pack . show

instance BA.ByteArrayAccess String where
  length        = BA.length . BS.pack
  withByteArray = BA.withByteArray . BS.pack

-- TODO how do I remove these boilerplate instances?

instance Semigroup Coin where
  (Coin a) <> (Coin b) = Coin (a + b)

instance Monoid Coin where
  mempty = Coin 0
  mappend = (<>)

txid :: Tx -> TxId
txid = TxId . hash

txins :: Tx -> Set TxIn
txins = inputs . body

txouts :: Tx -> UTxO
txouts tx = UTxO $
  Map.fromList [(TxIn transId idx, out) | (out, idx) <- zip (outs tx) [0..]]
  where
    outs = outputs . body
    transId = txid tx

unionUTxO :: UTxO -> UTxO -> UTxO
unionUTxO (UTxO a) (UTxO b) = UTxO $ Map.union a b

balance :: UTxO -> Coin
balance (UTxO utxo) = foldr addCoins mempty utxo
  where addCoins (TxOut _ a) b = a <> b

sign :: SKey -> a -> Sig a
sign (SKey k) d = Sig d k

verify :: Eq a => VKey -> a -> Sig a -> Bool
verify (VKey vk) vd (Sig sd sk) = vk == sk && vd == sd

type Ledger = [Tx]

-- |Domain restriction TODO: better symbol?
(<|) :: Set TxIn -> UTxO -> UTxO
ins <| (UTxO utxo) =
  UTxO $ Map.filterWithKey (\k _ -> k `Set.member` ins) utxo

-- |Domain exclusion TODO: better symbol?
(!<|) :: Set TxIn -> UTxO -> UTxO
ins !<| (UTxO utxo) =
  UTxO $ Map.filterWithKey (\k _ -> k `Set.notMember` ins) utxo

data ValidationError = UnknownInputs
                     | IncreasedTotalBalance
                     | InsuffientTxWitnesses
                     | InsuffientCertWitnesses
                     deriving (Show, Eq)
data Validity = Valid | Invalid [ValidationError] deriving (Show, Eq)

instance Semigroup Validity where
  Valid <> b                 = b
  a <> Valid                 = a
  (Invalid a) <> (Invalid b) = Invalid (a ++ b)

instance Monoid Validity where
  mempty = Valid
  mappend = (<>)

data LedgerState =
  LedgerState
  { getUtxo :: UTxO
  , getAccounts :: Map HashKey Coin
  , getStKeys :: Set HashKey
  , getDelegations :: Map HashKey HashKey
  , getStPools :: Set HashKey
  , getRetiring :: Map HashKey Int
  , getEpoch :: Int
  } deriving (Show, Eq)

genesisId = TxId $ hash "in the begining"

genesisState :: [TxOut] -> LedgerState
genesisState outs = LedgerState
  (UTxO (Map.fromList
    [((TxIn genesisId idx), out) | (idx, out) <- zip [0..] outs]
  ))
  Map.empty
  Set.empty
  Map.empty
  Set.empty
  Map.empty
  0

validInputs :: Tx -> LedgerState -> Validity
validInputs tx l =
  if (txins tx) `Set.isSubsetOf` unspentInputs (getUtxo l)
    then Valid
    else Invalid [UnknownInputs]
  where unspentInputs (UTxO utxo) = Map.keysSet utxo

preserveBalance :: Tx -> LedgerState -> Validity
preserveBalance tx l =
  if balance (txouts tx) <= balance (txins tx <| (getUtxo l))
    then Valid
    else Invalid [IncreasedTotalBalance]

authTxin :: VKey -> TxIn -> UTxO -> Bool
authTxin key txin (UTxO utxo) =
  case Map.lookup txin utxo of
    Just (TxOut (AddrTxin pay _) _) -> hash key == pay
    _ -> False

witnessTxin :: Tx -> LedgerState -> Validity
witnessTxin (Tx txBody (Wits ws _)) l =
  if (Set.size ws) == (Set.size ins) && all (hasWitness ws) ins
    then Valid
    else Invalid [InsuffientTxWitnesses]
  where
    utxo = getUtxo l
    ins = inputs txBody
    hasWitness ws input = isJust $ find (isWitness txBody input utxo) ws
    isWitness tb inp utxo (WitTxin key sig) =
      verify key tb sig && authTxin key inp utxo

authCert :: VKey -> Cert -> Bool
authCert key cert = True -- TODO

witnessCert :: Tx -> Validity
witnessCert (Tx txBody (Wits _ ws)) =
  if (Set.size ws) == (Set.size cs) && all (hasWitness ws) cs
    then Valid
    else Invalid [InsuffientTxWitnesses]
  where
    cs = certs txBody
    hasWitness ws cert = isJust $ find (isWitness txBody cert) ws
    isWitness txBody cert (WitCert key sig) =
      verify key txBody sig && authCert key cert
--TODO combine with witnessTxin?

valid :: Tx -> LedgerState -> Validity
valid tx l =
  validInputs tx l
    <> preserveBalance tx l
    <> witnessTxin tx l
    <> witnessCert tx


applyTransaction :: Tx -> LedgerState -> LedgerState
applyTransaction tx l = LedgerState
                         { getUtxo = newUTxOs
                         , getAccounts = newAccounts
                         , getStKeys = newStKeys
                         , getDelegations = newDelegations
                         , getStPools = newStPools
                         , getRetiring = newRetiring
                         , getEpoch = newEpoch
                         }
  where
    newUTxOs = (txins tx !<| (getUtxo l) `unionUTxO` txouts tx)
    newAccounts = getAccounts l --TODO implement
    newStKeys = getStKeys l --TODO implement
    newDelegations = getDelegations l --TODO implement
    newStPools = getStPools l --TODO implement
    newRetiring = getRetiring l --TODO implement
    newEpoch = getEpoch l --TODO implement

asStateTransition :: Tx -> LedgerState -> Either [ValidationError] LedgerState
asStateTransition tx l =
  case valid tx l of
    Invalid errors -> Left errors
    Valid          -> Right $ applyTransaction tx l
