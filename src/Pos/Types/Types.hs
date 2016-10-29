{-# LANGUAGE DefaultSignatures      #-}
{-# LANGUAGE DeriveGeneric          #-}
{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE ScopedTypeVariables    #-}
{-# LANGUAGE StandaloneDeriving     #-}
{-# LANGUAGE TemplateHaskell        #-}
{-# LANGUAGE TypeFamilies           #-}
{-# LANGUAGE TypeSynonymInstances   #-}
{-# LANGUAGE UndecidableInstances   #-}

-- | Definitions of the most fundamental types.

module Pos.Types.Types
       (
         Coin (..)
       , coinF

       , Address (..)
       , addressF

       , TxSig
       , TxId
       , TxIn (..)
       , TxOut (..)
       , Tx (..)
       , txF

       , Utxo

       , FtsSeed (..)
       , Commitment (..)
       , Opening (..)
       , CommitmentSignature
       , CommitmentsMap
       , OpeningsMap
       , SharesMap
       , VssCertificate
       , VssCertificatesMap
       , SlotLeaders

       , Blockchain (..)
       , BodyProof (..)
       , ConsensusData (..)
       , Body (..)
       , GenericBlockHeader (..)
       , GenericBlock (..)

       , MainBlockchain
       , MainBlockHeader
       , MpcData (..)
       , MpcProof
       , ChainDifficulty (..)
       , MainToSign
       , MainBlock

       , GenesisBlockchain
       , GenesisBlockHeader
       , GenesisBlock

       , BlockHeader
       , HeaderHash
       , Block

       -- * Lenses
       , HasDifficulty (..)
       , HasEpochIndex (..)
       , HasHeaderHash (..)
       , HasPrevBlock (..)

       , blockHeader
       , blockLeaderKey
       , blockLeaders
       , blockMpc
       , blockSignature
       , blockSlot
       , blockTxs
       , gbBody
       , gbBodyProof
       , gbExtra
       , gbHeader
       , gcdDifficulty
       , gcdEpoch
       , gbhExtra
       , gbhPrevBlock
       , gbhBodyProof
       , getBlockHeader
       , headerDifficulty
       , headerLeaderKey
       , headerSignature
       , headerSlot
       , mbMpc
       , mbTxs
       , mdCommitments
       , mdOpenings
       , mdShares
       , mdVssCertificates
       , mcdSlot
       , mcdLeaderKey
       , mcdDifficulty
       , mcdSignature

       -- TODO: move it from here to Block.hs
       , blockDifficulty
       , mkGenericBlock
       , mkGenericHeader
       , mkMainBlock
       , mkMainBody
       , mkMainHeader
       , mkGenesisHeader
       , mkGenesisBlock

       , VerifyBlockParams (..)
       , VerifyHeaderExtra (..)
       , verifyBlock
       , verifyBlocks
       , verifyGenericBlock
       -- , verifyGenericHeader
       , verifyHeader
       ) where

import           Control.Lens         (Getter, Lens', choosing, ix, makeLenses, to, view,
                                       (^.), (^?), _3)
import           Data.Binary          (Binary)
import           Data.Binary.Orphans  ()
import           Data.Data            (Data)
import           Data.Default         (Default (def))
import           Data.DeriveTH        (derive, makeNFData)
import           Data.Hashable        (Hashable)
import           Data.MessagePack     (MessagePack (..))
import           Data.SafeCopy        (SafeCopy (..), base, contain, deriveSafeCopySimple,
                                       deriveSafeCopySimpleIndexedType, safeGet, safePut)
import           Data.Text.Buildable  (Buildable)
import qualified Data.Text.Buildable  as Buildable
import           Data.Vector          (Vector)
import           Formatting           (Format, bprint, build, int, sformat, (%))
import           Serokell.AcidState   ()
import qualified Serokell.Util.Base16 as B16
import           Serokell.Util.Text   (listJson)
import           Serokell.Util.Verify (VerificationRes (..), verifyGeneric)
import           Universum

import           Pos.Constants        (epochSlots)
import           Pos.Crypto           (EncShare, Hash, PublicKey, Secret, SecretKey,
                                       SecretProof, SecretSharingExtra, Share, Signature,
                                       Signed, VssPublicKey, hash, hashHexF, sign,
                                       toPublic, unsafeHash, verify)
import           Pos.Merkle           (MerkleRoot, MerkleTree, mkMerkleTree, mtRoot,
                                       mtSize)
import           Pos.Types.Slotting   (EpochIndex (..), LocalSlotIndex (..), SlotId (..),
                                       slotIdF)
import           Pos.Util             (makeLensesData)

----------------------------------------------------------------------------
-- Coin
----------------------------------------------------------------------------

-- | Coin is the least possible unit of currency.
newtype Coin = Coin
    { getCoin :: Word64
    } deriving (Num, Enum, Integral, Show, Ord, Real, Eq, Bounded, Generic, Binary, Hashable, Data, NFData)

instance MessagePack Coin

instance Buildable Coin where
    build = bprint (int%" coin(s)")

-- | Coin formatter which restricts type.
coinF :: Format r (Coin -> r)
coinF = build

----------------------------------------------------------------------------
-- Address
----------------------------------------------------------------------------

-- | Address is where you can send coins.
newtype Address = Address
    { getAddress :: PublicKey
    } deriving (Show, Eq, Generic, Buildable, Ord, Binary, Hashable, NFData)

instance MessagePack Address

addressF :: Format r (Address -> r)
addressF = build

----------------------------------------------------------------------------
-- Transaction
----------------------------------------------------------------------------

type TxId = Hash Tx

type TxSig = Signature (TxId, Word32, [TxOut])

-- | Transaction input.
data TxIn = TxIn
    { txInHash  :: !TxId    -- ^ Which transaction's output is used
    , txInIndex :: !Word32  -- ^ Index of the output in transaction's
                            -- outputs
    , txInSig   :: !TxSig   -- ^ Signature given by public key
                            -- corresponding to address referenced by
                            -- this input.
    } deriving (Eq, Ord, Show, Generic)

instance Binary TxIn
instance Hashable TxIn
instance MessagePack TxIn

instance Buildable TxIn where
    build TxIn {..} = bprint ("TxIn ("%build%", "%int%")") txInHash txInIndex

-- | Transaction output.
data TxOut = TxOut
    { txOutAddress :: !Address
    , txOutValue   :: !Coin
    } deriving (Eq, Ord, Show, Generic)

instance Binary TxOut
instance Hashable TxOut
instance MessagePack TxOut

instance Buildable TxOut where
    build TxOut {..} =
        bprint ("TxOut ("%build%", "%coinF%")") txOutAddress txOutValue

-- | Transaction.
data Tx = Tx
    { txInputs  :: ![TxIn]   -- ^ Inputs of transaction.
    , txOutputs :: ![TxOut]  -- ^ Outputs of transaction.
    } deriving (Eq, Ord, Show, Generic)

instance Binary Tx
instance Hashable Tx
instance MessagePack Tx

instance Buildable Tx where
    build Tx {..} =
        bprint
            ("Transaction with inputs "%listJson%", outputs: "%listJson)
            txInputs txOutputs

txF :: Format r (Tx -> r)
txF = build

----------------------------------------------------------------------------
-- UTXO
----------------------------------------------------------------------------

-- | Unspent transaction outputs.
--
-- Transaction inputs are identified by (transaction ID, index in list of
-- output) pairs.
type Utxo = Map (TxId, Word32) TxOut

----------------------------------------------------------------------------
-- MPC. It means multi-party computation, btw
----------------------------------------------------------------------------

-- | This is a random seed used for follow-the-satoshi. This seed is
-- randomly generated by each party and eventually then agree on the
-- same value.
newtype FtsSeed = FtsSeed
    { getFtsSeed :: ByteString
    } deriving (Show, Eq, Ord, Generic, Binary, NFData)

instance MessagePack FtsSeed

instance Buildable FtsSeed where
    build = B16.formatBase16 . getFtsSeed

-- | Commitment is a message generated during the first stage of
-- MPC. It contains encrypted shares and proof of secret.
data Commitment = Commitment
    { commExtra  :: !SecretSharingExtra
    , commProof  :: !SecretProof
    , commShares :: !(HashMap VssPublicKey EncShare)
    } deriving (Show, Eq, Generic)

instance Binary Commitment
instance MessagePack Commitment

-- | Signature which ensures that commitment was generated by node
-- with given public key for given epoch.
type CommitmentSignature = Signature (EpochIndex, Commitment)

-- | Opening reveals message.
newtype Opening = Opening
    { getOpening :: Secret
    } deriving (Show, Eq, Generic, Binary, Buildable)

instance MessagePack Opening

type CommitmentsMap = HashMap PublicKey (Commitment, CommitmentSignature)
type OpeningsMap = HashMap PublicKey Opening

-- | Each node generates a 'FtsSeed', breaks it into 'Share's, and sends
-- those encrypted shares to other nodes. In a 'SharesMap', for each node we
-- collect shares which said node has received and decrypted.
--
-- Specifically, if node identified by 'PublicKey' X has received a share
-- from node identified by key Y, this share will be at @sharesMap ! X ! Y@.
type SharesMap = HashMap PublicKey (HashMap PublicKey Share)

-- | VssCertificate allows VssPublicKey to participate in MPC.
-- Each stakeholder should create a Vss keypair, sign public key with signing
-- key and send it into blockchain.
--
-- Other nodes accept this certificate if it is valid and if node really
-- has some stake.
type VssCertificate = Signed VssPublicKey

-- | VssCertificatesMap contains all valid certificates collected
-- during some period of time.
type VssCertificatesMap = HashMap PublicKey VssCertificate

type SlotLeaders = Vector PublicKey

----------------------------------------------------------------------------
-- GenericBlock
----------------------------------------------------------------------------

-- | Blockchain type class generalizes some functionality common for
-- different blockchains.
class Blockchain p where
    -- | Proof of data stored in the body. Ensures immutability.
    data BodyProof p :: *
    -- | Consensus data which can be used to check consensus properties.
    data ConsensusData p :: *
    -- | Whatever extra data.
    type ExtraHeaderData p :: *
    type ExtraHeaderData p = ()
    -- | Block header used in this blockchain.
    type BBlockHeader p :: *
    type BBlockHeader p = GenericBlockHeader p

    -- | Body contains payload and other heavy data.
    data Body p :: *
    -- | Whatever extra data.
    type ExtraBodyData p :: *
    type ExtraBodyData p = ()
    -- | Block used in this blockchain.
    type BBlock p :: *
    type BBlock p = GenericBlock p

    mkBodyProof :: Body p -> BodyProof p
    checkBodyProof :: Body p -> BodyProof p -> Bool
    default checkBodyProof :: Eq (BodyProof p) => Body p -> BodyProof p -> Bool
    checkBodyProof body proof = mkBodyProof body == proof

-- | Header of block contains some kind of summary. There are various
-- benefits which people get by separating header from other data.
data GenericBlockHeader b = GenericBlockHeader
    { -- | Pointer to the header of the previous block.
      _gbhPrevBlock :: !(Hash (BBlockHeader b))
    , -- | Proof of body.
      _gbhBodyProof :: !(BodyProof b)
    , -- | Consensus data to verify consensus algorithm.
      _gbhConsensus :: !(ConsensusData b)
    , -- | Any extra data.
      _gbhExtra     :: !(ExtraHeaderData b)
    } deriving (Generic)

deriving instance
         (Show (BodyProof b), Show (ConsensusData b),
          Show (ExtraHeaderData b)) =>
         Show (GenericBlockHeader b)

deriving instance
         (Eq (BodyProof b), Eq (ConsensusData b),
          Eq (ExtraHeaderData b)) =>
         Eq (GenericBlockHeader b)

instance ( Binary (BodyProof b)
         , Binary (ConsensusData b)
         , Binary (ExtraHeaderData b)
         ) =>
         Binary (GenericBlockHeader b)

instance ( MessagePack (BodyProof b)
         , MessagePack (ConsensusData b)
         , MessagePack (ExtraHeaderData b)
         ) =>
         MessagePack (GenericBlockHeader b)

-- | In general Block consists of header and body. It may contain
-- extra data as well.
data GenericBlock b = GenericBlock
    { _gbHeader :: !(GenericBlockHeader b)
    , _gbBody   :: !(Body b)
    , _gbExtra  :: !(ExtraBodyData b)
    } deriving (Generic)

deriving instance
         (Show (GenericBlockHeader b), Show (Body b),
          Show (ExtraBodyData b)) =>
         Show (GenericBlock b)

deriving instance
         (Eq (BodyProof b), Eq (ConsensusData b), Eq (ExtraHeaderData b),
          Eq (Body b), Eq (ExtraBodyData b)) =>
         Eq (GenericBlock b)

instance ( Binary (BodyProof b)
         , Binary (ConsensusData b)
         , Binary (ExtraHeaderData b)
         , Binary (Body b)
         , Binary (ExtraBodyData b)
         ) =>
         Binary (GenericBlock b)

instance ( MessagePack (BodyProof b)
         , MessagePack (ConsensusData b)
         , MessagePack (ExtraHeaderData b)
         , MessagePack (Body b)
         , MessagePack (ExtraBodyData b)
         ) =>
         MessagePack (GenericBlock b)

----------------------------------------------------------------------------
-- MainBlock
----------------------------------------------------------------------------

-- | Represents blockchain consisting of main blocks, i. e. blocks
-- with transactions and MPC messages.
data MainBlockchain

-- | Chain difficulty represents necessary effort to generate a
-- chain. In the simplest case it can be number of blocks in chain.
newtype ChainDifficulty = ChainDifficulty
    { getChainDifficulty :: Word64
    } deriving (Show, Eq, Ord, Num, Enum, Real, Integral, Generic, Binary, Buildable)

instance MessagePack ChainDifficulty

type MainToSign = (HeaderHash, BodyProof MainBlockchain, SlotId, ChainDifficulty)

-- | MPC-related content of main body.
data MpcData = MpcData
    { -- | Commitments are added during the first phase of epoch.
      _mdCommitments     :: !CommitmentsMap
      -- | Openings are added during the second phase of epoch.
    , _mdOpenings        :: !OpeningsMap
      -- | Decrypted shares to be used in the third phase.
    , _mdShares          :: !SharesMap
      -- | Vss certificates are added at any time if they are valid and
      -- received from stakeholders.
    , _mdVssCertificates :: !VssCertificatesMap
    } deriving (Generic, Show)

instance Binary MpcData
instance MessagePack MpcData

-- | Proof of MpcData.
-- We can use ADS for commitments, opennings, shares as well,
-- if we find it necessary.
data MpcProof = MpcProof
    { mpCommitmentsHash     :: !(Hash CommitmentsMap)
    , mpOpeningsHash        :: !(Hash OpeningsMap)
    , mpSharesHash          :: !(Hash SharesMap)
    , mpVssCertificatesHash :: !(Hash VssCertificatesMap)
    } deriving (Show, Eq, Generic)

instance Binary MpcProof
instance MessagePack MpcProof

instance Blockchain MainBlockchain where
    -- | Proof of transactions list and MPC data.
    data BodyProof MainBlockchain = MainProof
        { mpNumber   :: !Word32
        , mpRoot     :: !(MerkleRoot Tx)
        , mpMpcProof :: !MpcProof
        } deriving (Show, Eq, Generic)
    data ConsensusData MainBlockchain = MainConsensusData
        { -- | Id of the slot for which this block was generated.
        _mcdSlot       :: !SlotId
        , -- | Public key of slot leader. Maybe later we'll see it is redundant.
        _mcdLeaderKey  :: !PublicKey
        , -- | Difficulty of chain ending in this block.
        _mcdDifficulty :: !ChainDifficulty
        , -- | Signature given by slot leader.
        _mcdSignature  :: !(Signature MainToSign)
        } deriving (Generic, Show)
    type BBlockHeader MainBlockchain = BlockHeader

    -- | In our cryptocurrency, body consists of a list of transactions
    -- and MPC messages.
    data Body MainBlockchain = MainBody
        { -- | Transactions are the main payload.
          -- TODO: currently we don't know for sure whether it should be
          -- MerkleTree or something list-like.
          _mbTxs         :: !(MerkleTree Tx)
        , -- | Data necessary for MPC.
          _mbMpc  :: !MpcData
        } deriving (Generic, Show)
    type BBlock MainBlockchain = Block

    mkBodyProof MainBody {_mbMpc = MpcData {..}, ..} =
        MainProof
        { mpNumber = mtSize _mbTxs
        , mpRoot = mtRoot _mbTxs
        , mpMpcProof =
            MpcProof
            { mpCommitmentsHash = hash _mdCommitments
            , mpOpeningsHash = hash _mdOpenings
            , mpSharesHash = hash _mdShares
            , mpVssCertificatesHash = hash _mdVssCertificates
            }
        }

instance Binary (BodyProof MainBlockchain)
instance Binary (ConsensusData MainBlockchain)
instance Binary (Body MainBlockchain)

instance MessagePack (BodyProof MainBlockchain)
instance MessagePack (ConsensusData MainBlockchain)
instance MessagePack (Body MainBlockchain)

type MainBlockHeader = GenericBlockHeader MainBlockchain

instance Buildable MainBlockHeader where
    build GenericBlockHeader {..} =
        bprint
            ("MainBlockHeader:\n"%
             "    previous block: "%hashHexF%"\n"%
             "    slot: "%slotIdF%"\n"%
             "    leader: "%build%"\n"%
             "    difficulty: "%int%"\n"
            )
            _gbhPrevBlock
            _mcdSlot
            _mcdLeaderKey
            _mcdDifficulty
      where
        MainConsensusData {..} = _gbhConsensus

-- | MainBlock is a block with transactions and MPC messages. It's the
-- main part of our consensus algorithm.
type MainBlock = GenericBlock MainBlockchain

-- TODO
instance Buildable MainBlock where
    build GenericBlock {..} =
        bprint
            ("MainBlock:\n"%
             "  "%build%
             "  transactions: "%listJson%"\n"
            )
            _gbHeader
            _mbTxs
      where
        MainBody {..} = _gbBody

----------------------------------------------------------------------------
-- GenesisBlock
----------------------------------------------------------------------------

-- | Represents blockchain consisting of genesis blocks.  Genesis
-- block doesn't have any special payload and is not strictly
-- necessary. However, it is good idea to store list of leaders
-- explicitly, because calculating it may be expensive operation. For
-- example, it is useful for SPV-clients.
data GenesisBlockchain

type GenesisBlockHeader = GenericBlockHeader GenesisBlockchain

instance Blockchain GenesisBlockchain where
    -- | Proof of GenesisBody is just a hash of slot leaders list.
    -- TODO: do we need a Merkle tree? This list probably won't be large.
    data BodyProof GenesisBlockchain = GenesisProof
        !(Hash (Vector PublicKey))
        deriving (Eq, Generic, Show)
    data ConsensusData GenesisBlockchain = GenesisConsensusData
        { -- | Index of the slot for which this genesis block is relevant.
          _gcdEpoch :: !EpochIndex
        , -- | Difficulty of the chain ending in this genesis block.
          _gcdDifficulty :: !ChainDifficulty
        } deriving (Generic, Show)
    type BBlockHeader GenesisBlockchain = BlockHeader

    -- | Body of genesis block consists of slot leaders for epoch
    -- associated with this block.
    data Body GenesisBlockchain = GenesisBody
        { _gbLeaders :: !SlotLeaders
        } deriving (Show, Generic)
    type BBlock GenesisBlockchain = Block

    mkBodyProof = GenesisProof . hash . _gbLeaders

instance Binary (BodyProof GenesisBlockchain)
instance Binary (ConsensusData GenesisBlockchain)
instance Binary (Body GenesisBlockchain)

instance MessagePack (BodyProof GenesisBlockchain)
instance MessagePack (ConsensusData GenesisBlockchain)
instance MessagePack (Body GenesisBlockchain)

type GenesisBlock = GenericBlock GenesisBlockchain

----------------------------------------------------------------------------
-- GenesisBlock ∪ MainBlock
----------------------------------------------------------------------------

type BlockHeader = Either GenesisBlockHeader MainBlockHeader
type HeaderHash = Hash BlockHeader

type Block = Either GenesisBlock MainBlock

----------------------------------------------------------------------------
-- Lenses. TODO: move to Block.hs and other modules or leave them here?
----------------------------------------------------------------------------

makeLenses ''GenericBlockHeader
makeLenses ''GenericBlock
makeLenses ''MpcData
makeLensesData ''ConsensusData ''MainBlockchain
makeLensesData ''ConsensusData ''GenesisBlockchain
makeLensesData ''Body ''MainBlockchain
makeLensesData ''Body ''GenesisBlockchain

gbBodyProof :: Lens' (GenericBlock b) (BodyProof b)
gbBodyProof = gbHeader . gbhBodyProof

headerSlot :: Lens' MainBlockHeader SlotId
headerSlot = gbhConsensus . mcdSlot

headerLeaderKey :: Lens' MainBlockHeader PublicKey
headerLeaderKey = gbhConsensus . mcdLeaderKey

headerSignature :: Lens' MainBlockHeader (Signature MainToSign)
headerSignature = gbhConsensus . mcdSignature

class HasDifficulty a where
    difficultyL :: Lens' a ChainDifficulty

instance HasDifficulty (ConsensusData MainBlockchain) where
    difficultyL = mcdDifficulty

instance HasDifficulty (ConsensusData GenesisBlockchain) where
    difficultyL = gcdDifficulty

instance HasDifficulty MainBlockHeader where
    difficultyL = gbhConsensus . difficultyL

instance HasDifficulty GenesisBlockHeader where
    difficultyL = gbhConsensus . difficultyL

instance HasDifficulty BlockHeader where
    difficultyL = choosing difficultyL difficultyL

instance HasDifficulty MainBlock where
    difficultyL = gbHeader . difficultyL

instance HasDifficulty GenesisBlock where
    difficultyL = gbHeader . difficultyL

instance HasDifficulty Block where
    difficultyL = choosing difficultyL difficultyL

class HasPrevBlock s a | s -> a where
    prevBlockL :: Lens' s (Hash a)

instance (a ~ BBlockHeader b) =>
         HasPrevBlock (GenericBlockHeader b) a where
    prevBlockL = gbhPrevBlock

instance (a ~ BBlockHeader b) =>
         HasPrevBlock (GenericBlock b) a where
    prevBlockL = gbHeader . gbhPrevBlock

instance (HasPrevBlock s a, HasPrevBlock s' a) =>
         HasPrevBlock (Either s s') a where
    prevBlockL = choosing prevBlockL prevBlockL

class HasHeaderHash a where
    headerHash :: a -> HeaderHash
    headerHashG :: Getter a HeaderHash
    headerHashG = to headerHash

instance HasHeaderHash MainBlockHeader where
    headerHash = hash . Right

instance HasHeaderHash GenesisBlockHeader where
    headerHash = hash . Left

instance HasHeaderHash BlockHeader where
    headerHash = hash

instance HasHeaderHash MainBlock where
    headerHash = hash . Right . view gbHeader

instance HasHeaderHash GenesisBlock where
    headerHash = hash . Left  . view gbHeader

instance HasHeaderHash Block where
    headerHash = hash . getBlockHeader

class HasEpochIndex a where
    epochIndexL :: Lens' a EpochIndex

instance HasEpochIndex SlotId where
    epochIndexL f SlotId {..} = (\a -> SlotId {siEpoch = a, ..}) <$> f siEpoch

instance HasEpochIndex MainBlock where
    epochIndexL = gbHeader . gbhConsensus . mcdSlot . epochIndexL

instance HasEpochIndex GenesisBlock where
    epochIndexL = gbHeader . gbhConsensus . gcdEpoch

instance (HasEpochIndex a, HasEpochIndex b) =>
         HasEpochIndex (Either a b) where
    epochIndexL = choosing epochIndexL epochIndexL

blockSlot :: Lens' MainBlock SlotId
blockSlot = gbHeader . headerSlot

blockLeaderKey :: Lens' MainBlock PublicKey
blockLeaderKey = gbHeader . headerLeaderKey

blockSignature :: Lens' MainBlock (Signature MainToSign)
blockSignature = gbHeader . headerSignature

blockMpc :: Lens' MainBlock MpcData
blockMpc = gbBody . mbMpc

blockTxs :: Lens' MainBlock (MerkleTree Tx)
blockTxs = gbBody . mbTxs

blockLeaders :: Lens' GenesisBlock SlotLeaders
blockLeaders = gbBody . gbLeaders

-- This gives a “redundant constraint” message warning which will be fixed in
-- lens-4.15 (not in LTS yet).
blockHeader :: Getter Block BlockHeader
blockHeader = to getBlockHeader

getBlockHeader :: Block -> BlockHeader
getBlockHeader = bimap (view gbHeader) (view gbHeader)

----------------------------------------------------------------------------
-- Block.hs. TODO: move it into Block.hs.
-- These functions are here because of GHC bug (trac 12127).
----------------------------------------------------------------------------

-- | Difficulty of the BlockHeader. 0 for genesis block, 1 for main block.
headerDifficulty :: BlockHeader -> ChainDifficulty
headerDifficulty (Left _)  = 0
headerDifficulty (Right _) = 1

-- | Difficulty of the Block, which is determined from header.
blockDifficulty :: Block -> ChainDifficulty
blockDifficulty = headerDifficulty . getBlockHeader

genesisHash :: Hash a
genesisHash = unsafeHash ("patak" :: Text)
{-# INLINE genesisHash #-}

mkGenericHeader
    :: forall b.
       (Binary (BBlockHeader b), Blockchain b)
    => Maybe (BBlockHeader b)
    -> Body b
    -> (Hash (BBlockHeader b) -> BodyProof b -> ConsensusData b)
    -> ExtraHeaderData b
    -> GenericBlockHeader b
mkGenericHeader prevHeader body consensus extra =
    GenericBlockHeader
    { _gbhPrevBlock = h
    , _gbhBodyProof = proof
    , _gbhConsensus = consensus h proof
    , _gbhExtra = extra
    }
  where
    h :: Hash (BBlockHeader b)
    h = maybe genesisHash hash prevHeader
    proof = mkBodyProof body

mkGenericBlock
    :: forall b.
       (Binary (BBlockHeader b), Blockchain b)
    => Maybe (BBlockHeader b)
    -> Body b
    -> (Hash (BBlockHeader b) -> BodyProof b -> ConsensusData b)
    -> ExtraHeaderData b
    -> ExtraBodyData b
    -> GenericBlock b
mkGenericBlock prevHeader body consensus extraH extraB =
    GenericBlock {_gbHeader = header, _gbBody = body, _gbExtra = extraB}
  where
    header = mkGenericHeader prevHeader body consensus extraH

mkMainHeader
    :: Maybe BlockHeader
    -> SlotId
    -> SecretKey
    -> Body MainBlockchain
    -> MainBlockHeader
mkMainHeader prevHeader slotId sk body =
    mkGenericHeader prevHeader body consensus ()
  where
    difficulty = maybe 0 (succ . view difficultyL) prevHeader
    signature prevHash proof = sign sk (prevHash, proof, slotId, difficulty)
    consensus prevHash proof =
        MainConsensusData
        { _mcdSlot = slotId
        , _mcdLeaderKey = toPublic sk
        , _mcdDifficulty = difficulty
        , _mcdSignature = signature prevHash proof
        }

mkMainBlock
    :: Maybe BlockHeader
    -> SlotId
    -> SecretKey
    -> Body MainBlockchain
    -> MainBlock
mkMainBlock prevHeader slotId sk body =
    GenericBlock
    { _gbHeader = mkMainHeader prevHeader slotId sk body
    , _gbBody = body
    , _gbExtra = ()
    }

mkGenesisHeader :: Maybe BlockHeader
                -> EpochIndex
                -> Body GenesisBlockchain
                -> GenesisBlockHeader
mkGenesisHeader prevHeader epoch body =
    mkGenericHeader prevHeader body consensus ()
  where
    difficulty = maybe 0 (succ . view difficultyL) prevHeader
    consensus _ _ =
        GenesisConsensusData {_gcdEpoch = epoch, _gcdDifficulty = difficulty}

mkGenesisBlock :: Maybe BlockHeader -> EpochIndex -> SlotLeaders -> GenesisBlock
mkGenesisBlock prevHeader epoch leaders =
    GenericBlock
    { _gbHeader = mkGenesisHeader prevHeader epoch body
    , _gbBody = body
    , _gbExtra = ()
    }
  where
    body = GenesisBody leaders

mkMainBody :: [Tx] -> MpcData -> Body MainBlockchain
mkMainBody txs mpc = MainBody {_mbTxs = mkMerkleTree txs, _mbMpc = mpc}

verifyConsensusLocal :: BlockHeader -> VerificationRes
verifyConsensusLocal (Left _)       = mempty
verifyConsensusLocal (Right header) =
    verifyGeneric
        [ ( verify pk (_gbhPrevBlock, _gbhBodyProof, slotId, d) sig
          , "can't verify signature")
        , (siSlot slotId < epochSlots, "slot index is not less than epochSlots")
        ]
  where
    GenericBlockHeader {_gbhConsensus = consensus, ..} = header
    pk = consensus ^. mcdLeaderKey
    slotId = consensus ^. mcdSlot
    d = consensus ^. mcdDifficulty
    sig = consensus ^. mcdSignature

-- | Extra data which may be used by verifyHeader function to do more checks.
data VerifyHeaderExtra = VerifyHeaderExtra
    { vhePrevHeader  :: !(Maybe BlockHeader)
    -- ^ Nothing means that block is unknown, not genesis.
    , vheNextHeader  :: !(Maybe BlockHeader)
    , vheCurrentSlot :: !(Maybe SlotId)
    , vheLeaders     :: !(Maybe SlotLeaders)
    }

-- | By default there is not extra data.
instance Default VerifyHeaderExtra where
    def =
        VerifyHeaderExtra
        { vhePrevHeader = Nothing
        , vheNextHeader = Nothing
        , vheCurrentSlot = Nothing
        , vheLeaders = Nothing
        }

maybeEmpty :: Monoid m => (a -> m) -> Maybe a -> m
maybeEmpty = maybe mempty

-- | Check some predicates about BlockHeader. Number of checks depends
-- on extra data passed to this function. It tries to do as much as
-- possible.
verifyHeader :: VerifyHeaderExtra -> BlockHeader -> VerificationRes
verifyHeader VerifyHeaderExtra {..} h =
    verifyConsensusLocal h <> verifyGeneric checks
  where
    checks =
        mconcat
            [ maybeEmpty relatedToPrevHeader vhePrevHeader
            , maybeEmpty relatedToNextHeader vheNextHeader
            , maybeEmpty relatedToCurrentSlot vheCurrentSlot
            , maybeEmpty relatedToLeaders vheLeaders
            ]
    checkHash expectedHash actualHash =
        ( expectedHash == actualHash
        , sformat
              ("inconsistent hash (expected " %build % ", found" %build % ")")
              expectedHash
              actualHash)
    checkDifficulty expectedDifficulty actualDifficulty =
        ( expectedDifficulty == actualDifficulty
        , sformat
              ("incorrect difficulty (expected " %int % ", found " %int % ")")
              expectedDifficulty
              actualDifficulty)
    relatedToPrevHeader prevHeader =
        [ checkDifficulty
              (prevHeader ^. difficultyL + headerDifficulty h)
              (h ^. difficultyL)
        , checkHash (hash prevHeader) (h ^. prevBlockL)
        ]
    relatedToNextHeader nextHeader =
        [ checkDifficulty
              (nextHeader ^. difficultyL - headerDifficulty nextHeader)
              (h ^. difficultyL)
        , checkHash (hash h) (nextHeader ^. prevBlockL)
        ]
    relatedToCurrentSlot curSlotId =
        [ ( either (const True) ((<= curSlotId) . view headerSlot) h
          , "block is from slot which hasn't happened yet")
        ]
    relatedToLeaders leaders =
        case h of
            Left _ -> []
            Right mainHeader ->
                [ ( (Just (mainHeader ^. headerLeaderKey) ==
                     leaders ^?
                     ix (fromIntegral $ siSlot $ mainHeader ^. headerSlot))
                  , "block's leader is different from expected one")
                ]

-- | Perform cheap checks of GenericBlock, which can be done using
-- only block itself. Checks which can be done using only header are
-- ignored here. It is assumed that they will be done separately.
verifyGenericBlock :: forall b . Blockchain b => GenericBlock b -> VerificationRes
verifyGenericBlock blk =
    verifyGeneric
        [ ( checkBodyProof (blk ^. gbBody) (blk ^. gbBodyProof)
          , "body proof doesn't prove body")
        ]

-- | Parameters of Block verification.
-- Note: to check that block references previous block and/or is referenced
-- by next block, use header verification (via vbpVerifyHeader).
data VerifyBlockParams = VerifyBlockParams
    { vbpVerifyHeader  :: !(Maybe VerifyHeaderExtra)
    , vbpVerifyGeneric :: !Bool
    }

-- | By default nothing is checked.
instance Default VerifyBlockParams where
    def =
        VerifyBlockParams
        { vbpVerifyHeader = Nothing
        , vbpVerifyGeneric = False
        }

-- | Check predicates defined by VerifyBlockParams.
verifyBlock :: VerifyBlockParams -> Block -> VerificationRes
verifyBlock VerifyBlockParams {..} blk =
    mconcat
        [ verifyG
        , maybeEmpty (flip verifyHeader (getBlockHeader blk)) vbpVerifyHeader
        ]
  where
    verifyG =
        if vbpVerifyGeneric
            then either verifyGenericBlock verifyGenericBlock blk
            else mempty

-- | Verify sequence of blocks. It is assumed that the leftmost block
-- is the oldest one.
-- TODO: foldl' is used here which eliminates laziness benefits essential for
-- VerificationRes. Is it true? Can we do something with it?
-- Apart from returning Bool.
verifyBlocks
    :: Foldable t
    => Maybe SlotId -> t Block -> VerificationRes
verifyBlocks curSlotId = (view _3) . foldl' step start
  where
    start :: (Maybe SlotLeaders, Maybe BlockHeader, VerificationRes)
    start = (Nothing, Nothing, mempty)
    step
        :: (Maybe SlotLeaders, Maybe BlockHeader, VerificationRes)
        -> Block
        -> (Maybe SlotLeaders, Maybe BlockHeader, VerificationRes)
    step (leaders, prevHeader, res) blk =
        let newLeaders =
                case blk of
                    Left genesisBlock -> Just $ genesisBlock ^. blockLeaders
                    Right _           -> leaders
            vhe =
                VerifyHeaderExtra
                { vhePrevHeader = prevHeader
                , vheNextHeader = Nothing
                , vheLeaders = newLeaders
                , vheCurrentSlot = curSlotId
                }
            vbp =
                VerifyBlockParams
                {vbpVerifyHeader = Just vhe, vbpVerifyGeneric = True}
        in (newLeaders, Just $ getBlockHeader blk, res <> verifyBlock vbp blk)

----------------------------------------------------------------------------
-- SafeCopy instances
----------------------------------------------------------------------------

-- These instances are all gathered at the end because otherwise we'd have to
-- sort types topologically

deriveSafeCopySimple 0 'base ''EpochIndex
deriveSafeCopySimple 0 'base ''LocalSlotIndex
deriveSafeCopySimple 0 'base ''SlotId
deriveSafeCopySimple 0 'base ''Coin
deriveSafeCopySimple 0 'base ''Address
deriveSafeCopySimple 0 'base ''TxIn
deriveSafeCopySimple 0 'base ''TxOut
deriveSafeCopySimple 0 'base ''Tx
deriveSafeCopySimple 0 'base ''FtsSeed
deriveSafeCopySimple 0 'base ''Commitment
deriveSafeCopySimple 0 'base ''Opening

-- Manually written instances can't be derived because
-- 'deriveSafeCopySimple' is not clever enough to add
-- “SafeCopy (Whatever a) =>” constaints.
instance ( SafeCopy (BodyProof b)
         , SafeCopy (ConsensusData b)
         , SafeCopy (ExtraHeaderData b)
         ) =>
         SafeCopy (GenericBlockHeader b) where
    getCopy =
        contain $
        do _gbhPrevBlock <- safeGet
           _gbhBodyProof <- safeGet
           _gbhConsensus <- safeGet
           _gbhExtra <- safeGet
           return $! GenericBlockHeader {..}
    putCopy GenericBlockHeader {..} =
        contain $
        do safePut _gbhPrevBlock
           safePut _gbhBodyProof
           safePut _gbhConsensus
           safePut _gbhExtra

instance ( SafeCopy (BodyProof b)
         , SafeCopy (ConsensusData b)
         , SafeCopy (ExtraHeaderData b)
         , SafeCopy (Body b)
         , SafeCopy (ExtraBodyData b)
         ) =>
         SafeCopy (GenericBlock b) where
    getCopy =
        contain $
        do _gbHeader <- safeGet
           _gbBody <- safeGet
           _gbExtra <- safeGet
           return $! GenericBlock {..}
    putCopy GenericBlock {..} =
        contain $
        do safePut _gbHeader
           safePut _gbBody
           safePut _gbExtra

deriveSafeCopySimple 0 'base ''ChainDifficulty
deriveSafeCopySimple 0 'base ''MpcData
deriveSafeCopySimple 0 'base ''MpcProof
deriveSafeCopySimpleIndexedType 0 'base ''BodyProof [''MainBlockchain]
deriveSafeCopySimpleIndexedType 0 'base ''BodyProof [''GenesisBlockchain]
deriveSafeCopySimpleIndexedType 0 'base ''ConsensusData [''MainBlockchain]
deriveSafeCopySimpleIndexedType 0 'base ''ConsensusData [''GenesisBlockchain]
deriveSafeCopySimpleIndexedType 0 'base ''Body [''MainBlockchain]
deriveSafeCopySimpleIndexedType 0 'base ''Body [''GenesisBlockchain]

----------------------------------------------------------------------------
-- Other derived instances
----------------------------------------------------------------------------

derive makeNFData ''TxOut
