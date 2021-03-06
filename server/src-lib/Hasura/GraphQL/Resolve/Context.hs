{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE MultiWayIf        #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}

module Hasura.GraphQL.Resolve.Context
  ( FieldMap
  , OrdByResolveCtx
  , OrdByResolveCtxElem
  , NullsOrder(..)
  , OrdTy(..)
  , RespTx
  , getFldInfo
  , getPGColInfo
  , getArg
  , withArg
  , withArgM
  , nameAsPath
  , PrepArgs
  , Convert
  , runConvert
  , prepare
  , module Hasura.GraphQL.Utils
  ) where

import           Data.Has
import           Hasura.Prelude

import qualified Data.ByteString.Lazy          as BL
import qualified Data.HashMap.Strict           as Map
import qualified Data.Sequence                 as Seq
import qualified Database.PG.Query             as Q
import qualified Language.GraphQL.Draft.Syntax as G

import           Hasura.GraphQL.Utils
import           Hasura.GraphQL.Validate.Field
import           Hasura.GraphQL.Validate.Types
import           Hasura.RQL.Types
import           Hasura.SQL.Types
import           Hasura.SQL.Value

import qualified Hasura.SQL.DML                as S

type FieldMap
  = Map.HashMap (G.NamedType, G.Name) (Either PGColInfo (RelInfo, S.BoolExp, Maybe Int, Bool))

data OrdTy
  = OAsc
  | ODesc
  deriving (Show, Eq)

data NullsOrder
  = NFirst
  | NLast
  deriving (Show, Eq)

type RespTx = Q.TxE QErr BL.ByteString

-- context needed for sql generation
type OrdByResolveCtxElem = (PGColInfo, OrdTy, NullsOrder)

type OrdByResolveCtx
  = Map.HashMap (G.NamedType, G.EnumValue) OrdByResolveCtxElem

getFldInfo
  :: (MonadError QErr m, MonadReader r m, Has FieldMap r)
  => G.NamedType -> G.Name -> m (Either PGColInfo (RelInfo, S.BoolExp, Maybe Int, Bool))
getFldInfo nt n = do
  fldMap <- asks getter
  onNothing (Map.lookup (nt,n) fldMap) $
    throw500 $ "could not lookup " <> showName n <> " in " <>
    showNamedTy nt

getPGColInfo
  :: (MonadError QErr m, MonadReader r m, Has FieldMap r)
  => G.NamedType -> G.Name -> m PGColInfo
getPGColInfo nt n = do
  fldInfo <- getFldInfo nt n
  case fldInfo of
    Left pgColInfo -> return pgColInfo
    Right _        -> throw500 $
      "found relinfo when expecting pgcolinfo for "
      <> showNamedTy nt <> ":" <> showName n

getArg
  :: (MonadError QErr m)
  => ArgsMap
  -> G.Name
  -> m AnnGValue
getArg args arg =
  onNothing (Map.lookup arg args) $
  throw500 $ "missing argument: " <> showName arg

prependArgsInPath
  :: (MonadError QErr m)
  => m a -> m a
prependArgsInPath = withPathK "args"

nameAsPath
  :: (MonadError QErr m)
  => G.Name -> m a -> m a
nameAsPath name = withPathK (G.unName name)

withArg
  :: (MonadError QErr m)
  => ArgsMap
  -> G.Name
  -> (AnnGValue -> m a)
  -> m a
withArg args arg f = prependArgsInPath $ nameAsPath arg $
  getArg args arg >>= f

withArgM
  :: (MonadError QErr m)
  => ArgsMap
  -> G.Name
  -> (AnnGValue -> m a)
  -> m (Maybe a)
withArgM args arg f = prependArgsInPath $ nameAsPath arg $
  mapM f $ Map.lookup arg args

type PrepArgs = Seq.Seq Q.PrepArg

type Convert =
  StateT PrepArgs (ReaderT (FieldMap, OrdByResolveCtx) (Except QErr))

prepare
  :: (MonadState PrepArgs m)
  => (PGColType, PGColValue) -> m S.SQLExp
prepare (colTy, colVal) = do
  preparedArgs <- get
  put (preparedArgs Seq.|> binEncoder colVal)
  return $ toPrepParam (Seq.length preparedArgs + 1) colTy

runConvert
  :: (MonadError QErr m)
  => (FieldMap, OrdByResolveCtx) -> Convert a -> m (a, PrepArgs)
runConvert ctx m =
  either throwError return $
  runExcept $ runReaderT (runStateT m Seq.empty) ctx
