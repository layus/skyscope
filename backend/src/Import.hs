{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

module Import where

import Common
import Control.Category ((>>>))
import Control.Concurrent (forkIO, getNumCapabilities, threadDelay)
import Control.Concurrent.STM (atomically, retry)
import Control.Concurrent.STM.TVar (TVar, modifyTVar, newTVarIO, readTVar, readTVarIO, stateTVar, writeTVar)
import Control.Monad.RWS (RWS, evalRWS)
import Control.Monad.RWS.Class
import Control.Monad.State (evalState)
import qualified Crypto.Hash.SHA256 as SHA256
import qualified Data.Attoparsec.Combinator as Parser
import Data.Attoparsec.Text (Parser)
import qualified Data.Attoparsec.Text as Parser
import Data.Bifunctor (first, second)
import qualified Data.ByteString as BS
import Data.ByteString.Builder (byteStringHex, toLazyByteString)
import qualified Data.ByteString.Lazy.Char8 as LBSC
import Data.Foldable (for_)
import Data.Functor (void, (<&>))
import Data.IntMap (IntMap)
import qualified Data.IntMap as IntMap
import Data.List (uncons)
import qualified Data.Map as Map
import Data.Maybe (fromMaybe, isJust)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Text.IO as Text
import qualified Data.Time.Clock as Clock
import Data.Traversable (for)
import Database.SQLite3 (SQLData (..))
import Foreign.C.Types (CInt (..), CLong (..))
import qualified Foreign.Marshal.Array as Marshal
import Foreign.Ptr (Ptr, castPtr)
import Foreign.Storable (sizeOf)
import Model
import Sqlite (Database)
import qualified Sqlite
import Prelude

importer :: FilePath -> IO ()
importer path = do
  putStrLn $ "importing graph: " <> path
  Sqlite.withDatabase path $ \database -> do
    optimiseDatabaseAccess database
    importGraph database
  putStrLn $ "indexing"
  Sqlite.withDatabase path $ \database -> do
    optimiseDatabaseAccess database
    indexing <- indexPathsAsync database
    atomically $
      readTVar indexing >>= \case
        False -> pure ()
        True -> retry

optimiseDatabaseAccess :: Database -> IO ()
optimiseDatabaseAccess database =
  Sqlite.executeStatements
    database
    [ ["pragma mmap_size = 10737418240;"],
      ["pragma journal_mode = WAL;"],
      ["pragma synchronous = off;"]
    ]

indexPathsAsync :: Database -> IO (TVar Bool)
indexPathsAsync database = do
  progress <- newTVarIO (0, 1)
  indexStartTime <- Clock.getCurrentTime
  void $ forkIO $ indexPaths database progress
  indexing <- newTVarIO True
  let showProgress = do
        threadDelay 100_000
        (done, total) <- readTVarIO progress
        timeTaken <- Clock.getCurrentTime <&> (`Clock.diffUTCTime` indexStartTime)
        let unitTime = Clock.nominalDiffTimeToSeconds timeTaken / fromInteger (fromIntegral $ max 1 done)
            expectedTime = ceiling $ fromInteger (fromIntegral $ total - done) * unitTime :: Integer
            ansi = if done < total then "37" else "32"
        putStrLn $
          "\x1b[1F\x1b[2K\x1b[" <> ansi <> "mindexed paths to "
            <> show done
            <> " nodes ("
            <> show total
            <> " total, "
            <> show expectedTime
            <> " seconds remaining)\x1b[0m"
        if done < total
          then showProgress
          else do
            putStrLn $ "  time taken = " <> show timeTaken <> " seconds"
            atomically $ writeTVar indexing False
  void $ forkIO showProgress
  pure indexing

importGraph :: Database -> IO ()
importGraph database = timed "importGraph" $ do
  createSchema database
  legacy <- getSkyscopeEnv "LEGACY_BAZEL"
  let parser =
        if isJust legacy
          then graphParserLegacy
          else graphParser
  (nodes, edges) <-
    Text.getContents <&> Parser.parseOnly parser >>= \case
      Left err -> error $ "failed to parse skyframe graph: " <> err
      Right graph -> pure graph
  let assignIndex node = gets (,node) <* modify (+ 1)
      indexedNodes = evalState (for nodes assignIndex) 1
      coerceMaybe = fromMaybe $ error "parser produced an edge with an unknown node"
      indexedEdges = coerceMaybe $
        for (Set.toList edges) $ \(Edge group source target) -> do
          (sourceIndex, _) <- Map.lookup source indexedNodes
          (targetIndex, _) <- Map.lookup target indexedNodes
          pure (group, sourceIndex, targetIndex)
  Sqlite.batchInsert database "node" ["idx", "hash", "data", "type"] $
    Map.assocs indexedNodes <&> \(nodeHash, (nodeIdx, Node nodeData nodeType)) ->
      SQLInteger nodeIdx : (SQLText <$> [nodeHash, nodeType <> ":" <> nodeData, nodeType])
  Sqlite.batchInsert database "edge" ["group_num", "source", "target"] $
    indexedEdges <&> \(g, s, t) -> SQLInteger <$> [fromIntegral g, s, t]
  where
    createSchema :: Database -> IO ()
    createSchema database =
      Sqlite.executeStatements
        database
        [ [ "CREATE TABLE node (",
            "  idx INTEGER,",
            "  hash TEXT,",
            "  data TEXT,",
            "  type TEXT,",
            "  PRIMARY KEY (idx),",
            "  UNIQUE (hash)",
            ");"
          ],
          [ "CREATE TABLE edge (",
            "  source INTEGER,",
            "  target INTEGER,",
            "  group_num INTEGER,",
            "  PRIMARY KEY (source, target),",
            "  FOREIGN KEY (source) REFERENCES node(idx),",
            "  FOREIGN KEY (target) REFERENCES node(idx)",
            ");"
          ],
          [ "CREATE TABLE path (",
            "  destination INTEGER,",
            "  steps BLOB,",
            "  PRIMARY KEY (destination),",
            "  FOREIGN KEY (destination) REFERENCES node(idx)",
            ");"
          ]
        ]

-- $> Import.checkParserEquivalence

checkParserEquivalence :: IO ()
checkParserEquivalence = do
  let zeroEdges = second $ Set.map $ \(Edge _ s t) -> Edge 0 s t
      resultLegacy = Parser.parseOnly graphParserLegacy skyframeExampleLegacy
      result = Parser.parseOnly graphParser skyframeExample
  if resultLegacy == (zeroEdges <$> result)
    then pure ()
    else error $ "parsers not equivalent"

keyParser :: Parser (NodeHash, Node)
keyParser = do
  nodeType <- Parser.takeWhile1 $ \c -> c /= ':' && c /= '\n'
  void $ Parser.char ':'
  nodeData <- Parser.takeTill $ \c -> c == '|' || c == '\n'
  let nodeHash =
        Text.decodeUtf8 $
          LBSC.toStrict $
            toLazyByteString $
              byteStringHex $ SHA256.hash $ Text.encodeUtf8 $ nodeType <> ":" <> nodeData
  pure (nodeHash, Node nodeData nodeType)

skippingWarning :: Parser a -> Parser a
skippingWarning parser = do
  void $ Parser.option "" $ Parser.string "Warning:"
  void $ Parser.manyTill Parser.anyChar $ Parser.string "\n\n"
  parser

graphParserLegacy :: Parser Graph
graphParserLegacy = skippingWarning $ do
  graph <- mconcat <$> nodeParser `Parser.sepBy1` Parser.endOfLine
  Parser.skipSpace
  Parser.endOfInput
  pure graph
  where
    nodeParser :: Parser Graph
    nodeParser = do
      source@(sourceHash, _) <- keyParser <* Parser.char '|'
      keyParser `Parser.sepBy` Parser.char '|' <&> \targets ->
        ( Map.fromList $ source : targets,
          Set.fromList $ Edge 0 sourceHash . fst <$> targets
        )

skyframeExampleLegacy :: Text
skyframeExampleLegacy =
  Text.unlines
    [ "Warning: the format of this information may change etc!",
      "",
      "BLUE_NODE:NodeData{e247f4c}|",
      "RED_NODE:NodeData{6566162}|GREEN_NODE:NodeData{aab8e2e}|BLUE_NODE:NodeData{e247f4c}|RED_NODE:NodeData{5cedeee}",
      "RED_NODE:NodeData{5cedeee}|GREEN_NODE:NodeData{aab8e2e}",
      "GREEN_NODE:NodeData{aab8e2e}|RED_NODE:NodeData{5cedeee}"
    ]

graphParser :: Parser Graph
graphParser = skippingWarning $ do
  graph <- mconcat <$> Parser.many1 nodeParser
  Parser.skipSpace
  Parser.endOfInput
  pure graph
  where
    nodeParser :: Parser Graph
    nodeParser = do
      Parser.skipSpace
      (sourceHash, sourceNode) <- keyParser
      targets <- concat . traverse sequenceA <$> Parser.many' groupParser
      pure $
        mconcat $
          targets <&> \(groupNum, (targetHash, targetNode)) ->
            ( Map.fromList [(sourceHash, sourceNode), (targetHash, targetNode)],
              Set.singleton $ Edge groupNum sourceHash targetHash
            )

    groupParser :: Parser (Int, [(NodeHash, Node)])
    groupParser = do
      Parser.skipSpace
      void $ Parser.string "Group "
      groupNum <- Parser.decimal
      void $ Parser.char ':'
      fmap (groupNum,) $
        Parser.many1 $ do
          Parser.endOfLine
          void $ Parser.string "    "
          keyParser <* Parser.endOfLine

skyframeExample :: Text
skyframeExample =
  Text.unlines
    [ "Warning: the format of this information may change etc!",
      "",
      "BLUE_NODE:NodeData{e247f4c}",
      "",
      "RED_NODE:NodeData{6566162}",
      "",
      "  Group 1:",
      "    BLUE_NODE:NodeData{e247f4c}",
      "",
      "    GREEN_NODE:NodeData{aab8e2e}",
      "",
      "  Group 2:",
      "    RED_NODE:NodeData{5cedeee}",
      "",
      "",
      "RED_NODE:NodeData{5cedeee}",
      "",
      "  Group 1:",
      "    GREEN_NODE:NodeData{aab8e2e}",
      "",
      "",
      "GREEN_NODE:NodeData{aab8e2e}",
      "",
      "  Group 1:",
      "    RED_NODE:NodeData{5cedeee}",
      "",
      ""
    ]

indexPaths :: Database -> TVar (Int, Int) -> IO ()
indexPaths database progress = do
  void $ Sqlite.executeSql database ["DELETE FROM path;"] []
  nodeCount <- Sqlite.executeSqlScalar database ["SELECT COUNT(idx) FROM node;"] [] <&> fromSQLInt
  atomically $ writeTVar progress (0, nodeCount)
  predMap <- makePredMap nodeCount
  let predMapSize = length predMap
  Marshal.allocaArray predMapSize $ \predMapPtr -> do
    Marshal.pokeArray predMapPtr $ fromIntegral <$> predMap
    destinations <- newTVarIO [1 .. fromIntegral nodeCount]
    let nextDest =
          atomically $
            stateTVar destinations $
              uncons >>> \case
                Just (next, remaining) -> (Just next, remaining)
                Nothing -> (Nothing, [])
        worker stepMapPtr =
          nextDest >>= \case
            Just destination -> do
              stepMapSize <- Import.c_indexPaths predMapPtr destination (fromIntegral nodeCount) stepMapPtr
              let stepMapSizeBytes = fromIntegral stepMapSize * sizeOf (0 :: CLong)
              stepMapBytes <- Marshal.peekArray stepMapSizeBytes $ castPtr stepMapPtr
              void $
                Sqlite.executeSql
                  database
                  ["INSERT INTO path (destination, steps) VALUES (?, ?);"]
                  [SQLInteger $ fromIntegral destination, SQLBlob $ BS.pack stepMapBytes]
              atomically $ modifyTVar progress $ first (+ 1)
              worker stepMapPtr
            Nothing -> pure ()
    workerCount <- getNumCapabilities <&> (subtract 1)
    for_ [1 .. max 1 workerCount] $ const $ forkIO $ Marshal.allocaArray nodeCount worker
    let wait = atomically $ do
          remaining <- length <$> readTVar destinations
          if remaining > 0 then retry else pure ()
    wait
  where
    makePredMap :: Int -> IO [Int]
    makePredMap nodeCount = do
      predecessors <-
        Sqlite.executeSql database ["SELECT target, source FROM edge ORDER BY target;"] []
          <&> ((map $ \[t, s] -> (fromSQLInt t, [fromSQLInt s])) >>> IntMap.fromAscListWith (++))
      pure $ uncurry (++) $ evalRWS (for [0 .. nodeCount] serialisePreds) predecessors 0

    serialisePreds :: Int -> RWS (IntMap [Int]) [Int] Int Int
    serialisePreds i =
      asks (IntMap.lookup i) <&> fromMaybe [] >>= \case
        [pred] -> pure pred
        preds -> do
          let n = length preds
          tell $ n : preds
          offset <- get <* modify (+ (1 + n))
          pure $ negate offset

    fromSQLInt :: Num a => SQLData -> a
    fromSQLInt (SQLInteger n) = fromIntegral n
    fromSQLInt value = error $ "expected data type" <> show value

foreign import ccall safe "path.cpp"
  c_indexPaths ::
    Ptr CInt -> -- predMap
    CInt -> -- destination
    CInt -> -- nodeCount
    Ptr CLong -> -- stepMap
    IO CInt
