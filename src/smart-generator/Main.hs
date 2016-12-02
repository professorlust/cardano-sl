{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import           Control.TimeWarp.Rpc   (NetworkAddress)
import           Control.TimeWarp.Timed (Microsecond, for, fork_, ms, sec, wait)
import           Data.Default           (def)
import           Data.IORef             (modifyIORef', newIORef, readIORef)
import           Data.List              ((!!))
import           Data.Maybe             (fromMaybe)
import           Data.Time.Clock.POSIX  (getPOSIXTime)
import           Formatting             (float, int, sformat, (%))
import           Options.Applicative    (execParser)
import           System.FilePath.Posix  ((</>))
import           System.Random.Shuffle  (shuffleM)
import           System.Wlog            (logInfo)
import           Test.QuickCheck        (arbitrary, generate)
import           Universum

import           Pos.Constants          (k, slotDuration)
import           Pos.Crypto             (KeyPair (..), hash)
import           Pos.DHT                (DHTNodeType (..), dhtAddr, discoverPeers)
import           Pos.DHT.Real           (KademliaDHTInstance)
import           Pos.Genesis            (StakeDistribution (..), genesisPublicKeys,
                                         genesisSecretKeys, genesisUtxo)
import           Pos.Launcher           (BaseParams (..), LoggingParams (..),
                                         NodeParams (..), bracketDHTInstance, runNode,
                                         runProductionMode, runTimeSlaveReal, submitTxRaw)
import           Pos.Ssc.Class          (SscConstraint)
import           Pos.Ssc.GodTossing     (SscGodTossing)
import           Pos.Ssc.NistBeacon     (SscNistBeacon)
import           Pos.Ssc.SscAlgo        (SscAlgo (..))
import           Pos.State              (isTxVerified)
import           Pos.Types              (Tx (..))
import           Pos.Util.JsonLog       ()
import           Pos.WorkMode           (ProductionMode)

import           GenOptions             (GenOptions (..), optsInfo)
import           TxAnalysis             (checkWorker, createTxTimestamps, registerSentTx)
import           TxGeneration           (BambooPool, createBambooPool, curBambooTx,
                                         initTransaction, nextValidTx, resetBamboo)
import           Util


-- | Resend initTx with `slotDuration` period until it's verified
seedInitTx :: forall ssc . SscConstraint ssc
           => BambooPool -> Tx -> [NetworkAddress] -> ProductionMode ssc ()
seedInitTx bp initTx na = do
    logInfo "Issuing seed transaction"
    submitTxRaw na initTx
    logInfo "Waiting for 1 slot before resending..."
    wait $ for slotDuration
    -- If next tx is present in utxo, then everything is all right
    tx <- liftIO $ curBambooTx bp 1
    isVer <- isTxVerified tx
    if isVer
        then pure ()
        else seedInitTx bp initTx na

chooseSubset :: Double -> [a] -> [a]
chooseSubset share ls = take n ls
  where n = min 1 $ round $ share * fromIntegral (length ls)

runSmartGen :: forall ssc . SscConstraint ssc
            => KademliaDHTInstance -> NodeParams -> GenOptions -> IO ()
runSmartGen inst np@NodeParams{..} opts@GenOptions{..} =
    runProductionMode inst np $ do
    let i = fromIntegral goGenesisIdx
        getPosixMs = round . (*1000) <$> liftIO getPOSIXTime
        initTx = initTransaction opts

    bambooPool <- liftIO $ createBambooPool
                  (genesisPublicKeys !! i)
                  (genesisSecretKeys !! i)
                  initTx

    txTimestamps <- liftIO createTxTimestamps

    -- | Run all the usual node workers in order to get
    -- access to blockchain
    fork_ $ runNode @ssc []

    let logsFilePrefix = fromMaybe "." goLogsPrefix
    -- | Run the special worker to check new blocks and
    -- fill tx verification times
    fork_ $ checkWorker txTimestamps logsFilePrefix

    logInfo "STARTING TXGEN"
    peers <- discoverPeers DHTFull

    let neighboursAddrs = dhtAddr <$> peers
        forFold init ls act = foldM act init ls

    -- Seeding init tx
    seedInitTx bambooPool initTx neighboursAddrs

    -- Start writing tps file
    liftIO $ writeFile (logsFilePrefix </> tpsCsvFile) tpsCsvHeader

    let phaseDurationMs = fromIntegral (k + goPropThreshold) * slotDuration
        roundDurationSec = fromIntegral (goRoundPeriodRate + 1) *
                           fromIntegral (phaseDurationMs `div` sec 1)

    void $ forFold (goInitTps, goTpsIncreaseStep) [1 .. goRoundNumber] $
        \(goTPS, increaseStep) (roundNum :: Int) -> do
        -- Start writing verifications file
        liftIO $ writeFile (logsFilePrefix </> verifyCsvFile roundNum) verifyCsvHeader

        logInfo $ sformat ("Round "%int%" from "%int%": TPS "%float)
            roundNum goRoundNumber goTPS

        let tpsDelta = round $ 1000 / goTPS
            txNum = round $ roundDurationSec * goTPS

        realTxNum <- liftIO $ newIORef (0 :: Int)

        -- Make a pause between rounds
        wait $ for (round $ goRoundPause * fromIntegral (sec 1) :: Microsecond)

        beginT <- getPosixMs
        let startMeasurementsT =
                beginT + fromIntegral (phaseDurationMs `div` ms 1)

        forM_ [0 .. txNum - 1] $ \(idx :: Int) -> do
            preStartT <- getPosixMs
            logInfo $ sformat ("CURRENT TXNUM: "%int) txNum
            -- prevent periods longer than we expected
            unless (preStartT - beginT > round (roundDurationSec * 1000)) $ do
                startT <- getPosixMs

                -- Get a random subset of neighbours to send tx
                na <- liftIO $ chooseSubset goRecipientShare <$> shuffleM neighboursAddrs

                eTx <- nextValidTx bambooPool goTPS goPropThreshold
                case eTx of
                    Left parent -> do
                        logInfo $ sformat ("Transaction #"%int%" is not verified yet!") idx
                        logInfo "Resend the transaction parent again"
                        submitTxRaw na parent

                    Right transaction -> do
                        let curTxId = hash transaction
                        logInfo $ sformat ("Sending transaction #"%int) idx
                        submitTxRaw na transaction
                        when (startT >= startMeasurementsT) $ liftIO $ do
                            modifyIORef' realTxNum (+1)
                            -- put timestamp to current txmap
                            registerSentTx txTimestamps curTxId roundNum $ fromIntegral startT * 1000

                endT <- getPosixMs
                let runDelta = endT - startT
                wait $ for $ ms (max 0 $ tpsDelta - runDelta)

        liftIO $ resetBamboo bambooPool
        finishT <- getPosixMs

        realTxNumVal <- liftIO $ readIORef realTxNum

        let globalTime, realTPS :: Double
            globalTime = (fromIntegral (finishT - startMeasurementsT)) / 1000
            realTPS = (fromIntegral realTxNumVal) / globalTime
            (newTPS, newStep) = if realTPS >= goTPS - 5
                                then (goTPS + increaseStep, increaseStep)
                                else if realTPS >= goTPS * 0.8
                                     then (goTPS, increaseStep)
                                     else (realTPS, increaseStep / 2)

        putText "----------------------------------------"
        putText $ "Sending transactions took (s): " <> show globalTime
        putText $ "So real tps was: " <> show realTPS

        -- We collect tables of really generated tps
        liftIO $ appendFile (logsFilePrefix </> tpsCsvFile) $
            tpsCsvFormat (globalTime, goTPS, realTPS)

        -- Wait for 1 phase (to get all the last sent transactions)
        logInfo "Pausing transaction spawning for 1 phase"
        wait $ for phaseDurationMs

        return (newTPS, newStep)

-----------------------------------------------------------------------------
-- Main
-----------------------------------------------------------------------------

main :: IO ()
main = do
    opts@GenOptions {..} <- execParser optsInfo

    KeyPair _ sk <- generate arbitrary
    vssKeyPair <- generate arbitrary
    let logParams =
            LoggingParams
            { lpRunnerTag     = "smart-gen"
            , lpHandlerPrefix = goLogsPrefix
            , lpConfigPath    = goLogConfig
            }
        baseParams =
            BaseParams
            { bpLoggingParams      = logParams
            , bpPort               = 24962 + fromIntegral goGenesisIdx
            , bpDHTPeers           = goDHTPeers
            , bpDHTKeyOrType       = Right DHTFull
            , bpDHTExplicitInitial = goDhtExplicitInitial
            }
        stakesDistr = case (goFlatDistr, goBitcoinDistr) of
            (Nothing, Nothing) -> def
            (Just _, Just _) ->
                panic "flat-distr and bitcoin distr are conflicting options"
            (Just (nodes, coins), Nothing) ->
                FlatStakes (fromIntegral nodes) (fromIntegral coins)
            (Nothing, Just (nodes, coins)) ->
                BitcoinStakes (fromIntegral nodes) (fromIntegral coins)

    bracketDHTInstance baseParams $ \inst -> do
        let timeSlaveParams =
                baseParams
                { bpLoggingParams = logParams { lpRunnerTag = "time-slave" }
                }

        systemStart <- runTimeSlaveReal inst timeSlaveParams

        let params =
                NodeParams
                { npDbPath      = Nothing
                , npRebuildDb   = False
                , npSystemStart = systemStart
                , npSecretKey   = sk
                , npVssKeyPair  = vssKeyPair
                , npBaseParams  = baseParams
                , npCustomUtxo  = Just $ genesisUtxo stakesDistr
                , npTimeLord    = False
                , npJLFile      = goJLFile
                , npSscEnabled  = False
                }

        case goSscAlgo of
            GodTossingAlgo -> putText "Using MPC coin tossing" *>
                              runSmartGen @SscGodTossing inst params opts
            NistBeaconAlgo -> putText "Using NIST beacon" *>
                              runSmartGen @SscNistBeacon inst params opts
