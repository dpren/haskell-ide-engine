{-# LANGUAGE CPP                 #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- {-# LANGUAGE FlexibleInstances #-}
-- {-# LANGUAGE TypeSynonymInstances #-}
module Haskell.Ide.Engine.Plugin.HaRe where

import           ConLike
import           Control.Monad.State
import           Control.Monad.Trans.Control
import           Control.Monad.Trans.Except
import           Data.Aeson
import qualified Data.Aeson.Types                             as J
import           Data.Algorithm.Diff
import           Data.Algorithm.DiffOutput
import           Data.Bifunctor
import           Data.Either
import           Data.Foldable
import           Data.IORef
import qualified Data.List
import qualified Data.Map                                     as Map
import           Data.Maybe
import           Data.Monoid
import qualified Data.Set                                     as Set
import qualified Data.Text                                    as T
import qualified Data.Text.IO                                 as T
import           Data.Typeable
import           DataCon
import           Exception
import           FastString
import           GHC
import           GHC.Generics                                 (Generic)
import qualified GhcMod.Error                                 as GM
import qualified GhcMod.Monad                                 as GM
import qualified GhcMod.Utils                                 as GM
import qualified GhcMod.LightGhc                              as GM
import           Haskell.Ide.Engine.ArtifactMap
import           Haskell.Ide.Engine.MonadFunctions
import           Haskell.Ide.Engine.MonadTypes
import           Haskell.Ide.Engine.PluginUtils
import           Haskell.Ide.Engine.Plugin.GhcMod            (setTypecheckedModule)
import           HscTypes
import           Language.Haskell.GHC.ExactPrint.Print
import qualified Language.Haskell.LSP.Core                    as Core
import qualified Language.Haskell.LSP.TH.DataTypesJSON        as J
import           Language.Haskell.Refact.API                  hiding (logm)
import           Language.Haskell.Refact.HaRe
import           Language.Haskell.Refact.Utils.Monad          hiding (logm)
import           Language.Haskell.Refact.Utils.MonadFunctions
import           Module
import           Name
import           Outputable                                   (Outputable)
import           Packages
import           SrcLoc
import           TcEnv
import           Var
-- ---------------------------------------------------------------------

hareDescriptor :: PluginDescriptor
hareDescriptor = PluginDescriptor
  { pluginName = "HaRe"
  , pluginDesc = "A Haskell 2010 refactoring tool. HaRe supports the full "
              <> "Haskell 2010 standard, through making use of the GHC API.  HaRe attempts to "
              <> "operate in a safe way, by first writing new files with proposed changes, and "
              <> "only swapping these with the originals when the change is accepted. "
  , pluginCommands =
      [ PluginCommand "demote" "Move a definition one level down"
          demoteCmd
      , PluginCommand "dupdef" "Duplicate a definition"
          dupdefCmd
      , PluginCommand "iftocase" "Converts an if statement to a case statement"
          iftocaseCmd
      , PluginCommand "liftonelevel" "Move a definition one level up from where it is now"
          liftonelevelCmd
      , PluginCommand "lifttotoplevel" "Move a definition to the top level from where it is now"
          lifttotoplevelCmd
      , PluginCommand "rename" "rename a variable or type"
          renameCmd
      , PluginCommand "deletedef" "Delete a definition"
          deleteDefCmd
      , PluginCommand "genapplicative" "Generalise a monadic function to use applicative"
          genApplicativeCommand
      ]
  }

-- ---------------------------------------------------------------------

customOptions :: Int -> J.Options
customOptions n = J.defaultOptions { J.fieldLabelModifier = J.camelTo2 '_' . drop n}

data HarePoint =
  HP { hpFile :: Uri
     , hpPos  :: Position
     } deriving (Eq,Generic,Show)

instance FromJSON HarePoint where
  parseJSON = genericParseJSON $ customOptions 2
instance ToJSON HarePoint where
  toJSON = genericToJSON $ customOptions 2

data HarePointWithText =
  HPT { hptFile :: Uri
      , hptPos  :: Position
      , hptText :: T.Text
      } deriving (Eq,Generic,Show)

instance FromJSON HarePointWithText where
  parseJSON = genericParseJSON $ customOptions 3
instance ToJSON HarePointWithText where
  toJSON = genericToJSON $ customOptions 3

data HareRange =
  HR { hrFile     :: Uri
     , hrStartPos :: Position
     , hrEndPos   :: Position
     } deriving (Eq,Generic,Show)

instance FromJSON HareRange where
  parseJSON = genericParseJSON $ customOptions 2
instance ToJSON HareRange where
  toJSON = genericToJSON $ customOptions 2

-- ---------------------------------------------------------------------

demoteCmd :: CommandFunc HarePoint WorkspaceEdit
demoteCmd  = CmdSync $ \(HP uri pos) ->
  demoteCmd' uri pos

demoteCmd' :: Uri -> Position -> IdeGhcM (IdeResponse WorkspaceEdit)
demoteCmd' uri pos =
  pluginGetFile "demote: " uri $ \file -> do
    runHareCommand "demote" (compDemote file (unPos pos))

-- compDemote :: FilePath -> SimpPos -> IO [FilePath]

-- ---------------------------------------------------------------------

dupdefCmd :: CommandFunc HarePointWithText WorkspaceEdit
dupdefCmd = CmdSync $ \(HPT uri pos name) ->
  dupdefCmd' uri pos name

dupdefCmd' :: Uri -> Position -> T.Text -> IdeGhcM (IdeResponse WorkspaceEdit)
dupdefCmd' uri pos name =
  pluginGetFile "dupdef: " uri $ \file -> do
    runHareCommand  "dupdef" (compDuplicateDef file (T.unpack name) (unPos pos))

-- compDuplicateDef :: FilePath -> String -> SimpPos -> IO [FilePath]

-- ---------------------------------------------------------------------

iftocaseCmd :: CommandFunc HareRange WorkspaceEdit
iftocaseCmd = CmdSync $ \(HR uri startPos endPos) ->
  iftocaseCmd' uri (Range startPos endPos)

iftocaseCmd' :: Uri -> Range -> IdeGhcM (IdeResponse WorkspaceEdit)
iftocaseCmd' uri (Range startPos endPos) =
  pluginGetFile "iftocase: " uri $ \file -> do
    runHareCommand "iftocase" (compIfToCase file (unPos startPos) (unPos endPos))

-- compIfToCase :: FilePath -> SimpPos -> SimpPos -> IO [FilePath]

-- ---------------------------------------------------------------------

liftonelevelCmd :: CommandFunc HarePoint WorkspaceEdit
liftonelevelCmd = CmdSync $ \(HP uri pos) ->
  liftonelevelCmd' uri pos

liftonelevelCmd' :: Uri -> Position -> IdeGhcM (IdeResponse WorkspaceEdit)
liftonelevelCmd' uri pos =
  pluginGetFile "liftonelevelCmd: " uri $ \file -> do
    runHareCommand "liftonelevel" (compLiftOneLevel file (unPos pos))

-- compLiftOneLevel :: FilePath -> SimpPos -> IO [FilePath]

-- ---------------------------------------------------------------------

lifttotoplevelCmd :: CommandFunc HarePoint WorkspaceEdit
lifttotoplevelCmd = CmdSync $ \(HP uri pos) ->
  lifttotoplevelCmd' uri pos

lifttotoplevelCmd' :: Uri -> Position -> IdeGhcM (IdeResponse WorkspaceEdit)
lifttotoplevelCmd' uri pos =
  pluginGetFile "lifttotoplevelCmd: " uri $ \file -> do
    runHareCommand "lifttotoplevel" (compLiftToTopLevel file (unPos pos))

-- compLiftToTopLevel :: FilePath -> SimpPos -> IO [FilePath]

-- ---------------------------------------------------------------------

renameCmd :: CommandFunc HarePointWithText WorkspaceEdit
renameCmd = CmdSync $ \(HPT uri pos name) ->
  renameCmd' uri pos name

renameCmd' :: Uri -> Position -> T.Text -> IdeGhcM (IdeResponse WorkspaceEdit)
renameCmd' uri pos name =
  pluginGetFile "rename: " uri $ \file -> do
      runHareCommand "rename" (compRename file (T.unpack name) (unPos pos))

-- compRename :: FilePath -> String -> SimpPos -> IO [FilePath]

-- ---------------------------------------------------------------------

deleteDefCmd :: CommandFunc HarePoint WorkspaceEdit
deleteDefCmd  = CmdSync $ \(HP uri pos) ->
  deleteDefCmd' uri pos

deleteDefCmd' :: Uri -> Position -> IdeGhcM (IdeResponse WorkspaceEdit)
deleteDefCmd' uri pos =
  pluginGetFile "deletedef: " uri $ \file -> do
      runHareCommand "deltetedef" (compDeleteDef file (unPos pos))

-- compDeleteDef ::FilePath -> SimpPos -> RefactGhc [ApplyRefacResult]

-- ---------------------------------------------------------------------

genApplicativeCommand :: CommandFunc HarePoint WorkspaceEdit
genApplicativeCommand  = CmdSync $ \(HP uri pos) ->
  genApplicativeCommand' uri pos

genApplicativeCommand' :: Uri -> Position -> IdeGhcM (IdeResponse WorkspaceEdit)
genApplicativeCommand' uri pos =
  pluginGetFile "genapplicative: " uri $ \file -> do
      runHareCommand "genapplicative" (compGenApplicative file (unPos pos))


-- ---------------------------------------------------------------------

getRefactorResult :: [ApplyRefacResult] -> [(FilePath,T.Text)]
getRefactorResult = map getNewFile . filter fileModified
  where fileModified ((_,m),_) = m == RefacModified
        getNewFile ((file,_),(ann, parsed)) = (file, T.pack $ exactPrint parsed ann)

makeRefactorResult :: [(FilePath,T.Text)] -> IdeGhcM WorkspaceEdit
makeRefactorResult changedFiles = do
  let
    diffOne :: (FilePath, T.Text) -> IdeGhcM WorkspaceEdit
    diffOne (fp, newText) = do
      origText <- GM.withMappedFile fp $ liftIO . T.readFile
      -- TODO: remove this logging once we are sure we have a working solution
      logm $ "makeRefactorResult:groupedDiff = " ++ show (getGroupedDiff (lines $ T.unpack origText) (lines $ T.unpack newText))
      logm $ "makeRefactorResult:diffops = " ++ show (diffToLineRanges $ getGroupedDiff (lines $ T.unpack origText) (lines $ T.unpack newText))
      return $ diffText (filePathToUri fp, origText) newText
  diffs <- mapM diffOne changedFiles
  return $ Core.reverseSortEdit $ fold diffs

-- ---------------------------------------------------------------------

nonExistentCacheErr :: String -> IdeResponse a
nonExistentCacheErr meth =
  IdeResponseFail $
    IdeError PluginError
             (T.pack $ meth <> ": \"" <> "module not loaded" <> "\"")
             Null

invalidCursorErr :: String -> IdeResponse a
invalidCursorErr meth =
  IdeResponseFail $
    IdeError PluginError
             (T.pack $ meth <> ": \"" <> "Invalid cursor position" <> "\"")
             Null

someErr :: String -> String -> IdeResponse a
someErr meth err =
  IdeResponseFail $
    IdeError PluginError
             (T.pack $ meth <> ": " <> err)
             Null

-- ---------------------------------------------------------------------

data NameMapData = NMD
  { inverseNameMap ::  !(Map.Map Name [SrcSpan])
  } deriving (Typeable)

invert :: (Ord v) => Map.Map k v -> Map.Map v [k]
invert m = Map.fromListWith (++) [(v,[k]) | (k,v) <- Map.toList m]

instance ModuleCache NameMapData where
  cacheDataProducer cm = pure $ NMD inm
    where nm  = initRdrNameMap $ tcMod cm
          inm = invert nm

-- ---------------------------------------------------------------------

getSymbols :: Uri -> IdeM (IdeResponse [J.SymbolInformation])
getSymbols uri = pluginGetFile "getSymbols: " uri $ \file -> do
    mcm <- getCachedModule file
    case mcm of
      Nothing -> return $ IdeResponseOk []
      Just cm -> do
          let tm = tcMod cm
              rfm = revMap cm
              hsMod = unLoc $ pm_parsed_source $ tm_parsed_module tm
              imports = hsmodImports hsMod
              imps  = concatMap (goImport . unLoc) imports
              decls = concatMap (go . unLoc) $ hsmodDecls hsMod
              s x = T.pack . showGhc <$> x

              go :: HsDecl RdrName -> [(J.SymbolKind,Located T.Text,Maybe T.Text)]
              go (TyClD FamDecl { tcdFam = FamilyDecl { fdLName = n } }) = pure (J.SkClass, s n, Nothing)
              go (TyClD SynDecl { tcdLName = n }) = pure (J.SkClass, s n, Nothing)
              go (TyClD DataDecl { tcdLName = n, tcdDataDefn = HsDataDefn { dd_cons = cons } }) =
                (J.SkClass, s n, Nothing) : concatMap (processCon (unLoc $ s n) . unLoc) cons
              go (TyClD ClassDecl { tcdLName = n, tcdSigs = sigs, tcdATs = fams }) =
                (J.SkInterface, sn, Nothing) :
                      concatMap (processSig (unLoc sn) . unLoc) sigs
                  ++  concatMap (map setCnt . go . TyClD . FamDecl . unLoc) fams
                where sn = s n
                      setCnt (k,n',_) = (k,n',Just (unLoc sn))
              go (ValD FunBind { fun_id = ln }) = pure (J.SkFunction, s ln, Nothing)
              go (ValD PatBind { pat_lhs = p }) =
                map (\n ->(J.SkMethod, s n, Nothing)) $ hsNamessRdr p
              go (ForD ForeignImport { fd_name = n }) = pure (J.SkFunction, s n, Nothing)
              go _ = []

              processSig :: T.Text
                         -> Sig RdrName
                         -> [(J.SymbolKind, Located T.Text, Maybe T.Text)]
              processSig cnt (ClassOpSig False names _) =
                map (\n ->(J.SkMethod,s n, Just cnt)) names
              processSig _ _ = []

              processCon :: T.Text
                         -> ConDecl RdrName
                         -> [(J.SymbolKind, Located T.Text, Maybe T.Text)]
              processCon cnt ConDeclGADT { con_names = names } =
                map (\n -> (J.SkConstructor, s n, Just cnt)) names
              processCon cnt ConDeclH98 { con_name = name, con_details = dets } =
                (J.SkConstructor, sn, Just cnt) : xs
                where
                  sn = s name
                  xs = case dets of
                    RecCon (L _ rs) -> concatMap (map (f . rdrNameFieldOcc . unLoc)
                                                 . cd_fld_names
                                                 . unLoc) rs
                                         where f ln = (J.SkField, s ln, Just (unLoc sn))
                    _ -> []

              goImport :: ImportDecl RdrName -> [(J.SymbolKind, Located T.Text, Maybe T.Text)]
              goImport ImportDecl { ideclName = lmn, ideclAs = as, ideclHiding = meis } = a ++ xs
                where
                  im = (J.SkModule, lsmn, Nothing)
                  lsmn = s lmn
                  smn = unLoc lsmn
                  a = case as of
                            Just a' -> [(J.SkNamespace, lsmn, Just $ T.pack $ showGhc a')]
                            Nothing -> [im]
                  xs = case meis of
                         Just (False, eis) -> concatMap (f . unLoc) (unLoc eis)
                         _ -> []
                  f (IEVar n) = pure (J.SkFunction, s n, Just smn)
                  f (IEThingAbs n) = pure (J.SkClass, s n, Just smn)
                  f (IEThingAll n) = pure (J.SkClass, s n, Just smn)
                  f (IEThingWith n _ vars fields) =
                    let sn = s n in
                    (J.SkClass, sn, Just smn) :
                         map (\n' -> (J.SkFunction, s n', Just (unLoc sn))) vars
                      ++ map (\f' -> (J.SkField   , s f', Just (unLoc sn))) fields
                  f _ = []

              declsToSymbolInf :: (J.SymbolKind, Located T.Text, Maybe T.Text)
                               -> IdeM (Either T.Text J.SymbolInformation)
              declsToSymbolInf (kind, L l nameText, cnt) = do
                eloc <- srcSpan2Loc rfm l
                case eloc of
                  Left x -> return $ Left x
                  Right loc -> return $ Right $ J.SymbolInformation nameText kind loc cnt
          symInfs <- mapM declsToSymbolInf (imps ++ decls)
          return $ IdeResponseOk $ rights symInfs

-- ---------------------------------------------------------------------

data CompItem = CI
  { origName     :: Name
  , importedFrom :: T.Text
  , thingType    :: Maybe T.Text
  , label        :: T.Text
  } deriving (Show)

instance Eq CompItem where
  (CI n1 _ _ _) == (CI n2 _ _ _) = n1 == n2

instance Ord CompItem where
  compare (CI n1 _ _ _) (CI n2 _ _ _) = compare n1 n2

occNameToComKind :: OccName -> J.CompletionItemKind
occNameToComKind oc
  | isVarOcc  oc = J.CiFunction
  | isTcOcc   oc = J.CiClass
  | isDataOcc oc = J.CiConstructor
  | otherwise    = J.CiVariable

type HoogleQuery = T.Text

mkQuery :: T.Text -> T.Text -> HoogleQuery
mkQuery name importedFrom = name <> " module:" <> importedFrom
                                 <> " is:exact"

mkCompl :: CompItem -> J.CompletionItem
mkCompl CI{origName,importedFrom,thingType,label} =
  J.CompletionItem label kind (Just $ maybe "" (<>"\n") thingType <> importedFrom)
    Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing hoogleQuery
  where kind  = Just $ occNameToComKind $ occName origName
        hoogleQuery = Just $ toJSON $ mkQuery label importedFrom

mkModCompl :: T.Text -> J.CompletionItem
mkModCompl label =
  J.CompletionItem label (Just J.CiModule) Nothing
    Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing hoogleQuery
  where hoogleQuery = Just $ toJSON $ "module:" <> label

safeTyThingId :: TyThing -> Maybe Id
safeTyThingId (AnId i)                    = Just i
safeTyThingId (AConLike (RealDataCon dc)) = Just $ dataConWrapId dc
safeTyThingId _                           = Nothing


-- available completions in scope
data CachedCompletions = CC
  { unqualCompls :: [CompItem]
  , importDeclerations :: [ImportDecl Name]
  , allModNamesAsGiven :: [T.Text]
  , cachedLocalCmps :: [CompItem]
  , cachedQualifiedModNames :: [ModuleName]
  , cachedUnqualifiedModNames :: [ModuleName]
  } deriving (Typeable)

-- {-

instance ModuleCache CachedCompletions where
  -- cacheDataProducer :: CachedModule -> m CachedCompletions
  cacheDataProducer cm = do
    let tm = tcMod cm
        parsedMod = tm_parsed_module tm
        curMod = moduleName $ ms_mod $ pm_mod_summary parsedMod
        Just (_,limports,_,_) = tm_renamed_source tm
        -- Full canonical names of imported modules
        importDeclerations = map unLoc limports

        typeEnv = md_types $ snd $ tm_internals_ tm
        localVars = mapMaybe safeTyThingId $ typeEnvElts typeEnv
        varToLocalCmp var = CI name (showModName curMod) typ label
          where
            typ = Just $ T.pack $ showGhc $ varType var
            name = Var.varName var
            label = T.pack $ showGhc name
        
        localCmps = map varToLocalCmp localVars

        -- The given namespaces for the imported modules (ie. full name, or alias if used)
        allModNamesAsGiven = map (showModName . pickNamespace) importDeclerations

        --                  qual          unqual
        partitionedMods :: ([ModuleName], [ModuleName])
        partitionedMods = bimap (map iDeclToModName) (map iDeclToModName)
                      $ Data.List.partition ideclQualified importDeclerations

        cachedQualifiedModNames = fst partitionedMods
        cachedUnqualifiedModNames = snd partitionedMods

        getComplsFromModName :: GhcMonad m
          => ModuleName -> m (Set.Set CompItem)
        getComplsFromModName mn = do
          mminf <- getModuleInfo =<< findModule mn Nothing
          return $ case mminf of
            Nothing -> Set.empty
            Just minf ->
              Set.fromList $ map (modNameToCompItem mn) $ modInfoExports minf

        -- setCiTypesForImported :: (Traversable t, MonadIO m) => Maybe HscEnv -> t CompItem -> m (t CompItem)
        -- lookup up and set the thingType
        setCiTypesForImported Nothing xs = liftIO $ pure xs
        setCiTypesForImported (Just hscEnv) xs =
          liftIO $ forM xs $ \ci@CI{origName} -> do
            mt <- (Just <$> lookupGlobal hscEnv origName)
                    `catch` \(_ :: SourceError) -> return Nothing
            let typ = do
                  t <- mt
                  tyid <- safeTyThingId t
                  return $ T.pack $ showGhc $ varType tyid
            return $ ci {thingType = typ}

    unqualCompls <- do
      hscEnvRef <- ghcSession <$> readMTS
      hscEnv <- liftIO $ traverse readIORef hscEnvRef
      let getComplsGhc = maybe (const $ pure Set.empty) (\env -> GM.runLightGhc env . getComplsFromModName) hscEnv
      withoutTypes <- Set.toList . Set.unions <$> mapM getComplsGhc cachedUnqualifiedModNames
      unqualCompls <- setCiTypesForImported hscEnv withoutTypes
      return unqualCompls
    
    debugm $ "CC ##### "

    return $ CC 
      { unqualCompls = unqualCompls

      , importDeclerations = importDeclerations

      , allModNamesAsGiven  = allModNamesAsGiven
      , cachedLocalCmps = localCmps
      , cachedQualifiedModNames = cachedQualifiedModNames
      , cachedUnqualifiedModNames = cachedUnqualifiedModNames
      }




--}

iDeclToModName :: ImportDecl name -> ModuleName
iDeclToModName = unLoc . ideclName

showModName :: ModuleName -> T.Text
showModName = T.pack . moduleNameString

modNameToCompItem :: ModuleName -> Name -> CompItem
modNameToCompItem mn n =
  CI n (showModName mn) Nothing (T.pack $ showGhc n)

#if __GLASGOW_HASKELL__ >= 802
pickNamespace :: ImportDecl name -> ModuleName
pickNamespace imp = fromMaybe (iDeclToModName imp) (fmap GHC.unLoc $ ideclAs imp)
#else
pickNamespace :: ImportDecl name -> ModuleName
pickNamespace imp = fromMaybe (iDeclToModName imp) (ideclAs imp)
#endif


getCompletions :: Uri -> (T.Text, T.Text) -> IdeM (IdeResponse [J.CompletionItem])
getCompletions uri (qualifier, ident) = pluginGetFile "getCompletions: " uri $ \file ->
  let handlers  = [GM.GHandler $ \(ex :: SomeException) ->
                     return $ someErr "getCompletions" (show ex)
                  ] in
  flip GM.gcatches handlers $ do
  debugm $ "got prefix" ++ show (qualifier, ident)
  let noCache = return $ nonExistentCacheErr "getCompletions"
  let modQual = if T.null qualifier then "" else qualifier <> "."
  let fullPrefix = modQual <> ident
  withCachedModuleAndData file noCache $
    \_ CC{allModNamesAsGiven
        , unqualCompls
        , importDeclerations
        , cachedLocalCmps
        -- , cachedUnqualifiedModNames
      } -> do
      let filterComplsByIdent = filter ((ident `T.isPrefixOf`) . label)
          
          -- G:
          --  [CI { _label = "GM", _kind = Just CiModule, _... = Nothing }]
          --  [CI { _label = "GHC.Generics", _kind = Just CiModule, _... = Nothing }]
          modNameCompls = map mkModCompl
                    $ mapMaybe (T.stripPrefix $ modQual)
                    $ filter (fullPrefix `T.isPrefixOf`) allModNamesAsGiven


          -- if qualifier, we only need to return items under that namespace
          qualifiedModNames :: [(ModuleName, Maybe (Bool, [Name]))]
          qualifiedModNames
            | T.null qualifier = []
            | otherwise = mapMaybe func importDeclerations
              where func imp = do
                      let modName = iDeclToModName imp
                      -- allModNamesAsGiven == qualifier
                      guard (showModName (pickNamespace imp) == qualifier)
                      case ideclHiding imp of
                        Nothing ->
                          return (modName, Nothing)
                        Just (hasHiddens, L _ liens) ->
                          return (modName, Just (hasHiddens, concatMap (ieNames . unLoc) liens))

          getQualifedCompls :: GhcMonad m => m (Set.Set CompItem)
          getQualifedCompls = do
            xs <- forM qualifiedModNames $
              -- :: m (Set.Set CompItem)
              \(modName, mie) ->
                case mie of
                  --           names == members
                  Just (False, names) ->
                    return $ Set.fromList $ filterComplsByIdent $ map (modNameToCompItem modName) names
                  Just (True , names) -> do
                    compls <- getComplsFromModName modName
                    let hiddens = Set.fromList $ filterComplsByIdent $ map (modNameToCompItem modName) names
                    -- compls without hiddens
                    return $ Set.difference compls hiddens
                  Nothing ->
                    getComplsFromModName modName
            return $ Set.unions xs

          getComplsFromModName :: GhcMonad m
            => ModuleName -> m (Set.Set CompItem)
          getComplsFromModName mn = do
            mminf <- getModuleInfo =<< findModule mn Nothing
            return $ case mminf of
              Nothing -> Set.empty
              Just minf -> do
                let z = map (modNameToCompItem mn) $ modInfoExports minf
                Set.fromList $ filterComplsByIdent $ z

          setCiTypesForImported Nothing xs = liftIO $ pure xs
          setCiTypesForImported (Just hscEnv) xs =
            liftIO $ forM xs $ \ci@CI{origName} -> do
              mt <- (Just <$> lookupGlobal hscEnv origName)
                      `catch` \(_ :: SourceError) -> return Nothing
              let typ = do
                    t <- mt
                    tyid <- safeTyThingId t
                    return $ T.pack $ showGhc $ varType tyid
              return $ ci {thingType = typ}

      -- debugm $ "importDeclerations ~~~~~ " ++ show (map iDeclToModName importDeclerations)
      -- debugm $ "allModNamesAsGiven ~~~~~ " ++ show allModNamesAsGiven
      -- debugm $ "modNameCompls ~~~~~ " ++ show modNameCompls

      comps <- do
        hscEnvRef <- ghcSession <$> readMTS
        hscEnv <- liftIO $ traverse readIORef hscEnvRef
        if T.null qualifier then do
          -- let getComplsGhc = maybe (const $ pure Set.empty) (\env -> GM.runLightGhc env . getComplsFromModName) hscEnv
          -- xs <- Set.toList . Set.unions <$> mapM getComplsGhc cachedUnqualifiedModNames
          -- xs' <- setCiTypesForImported hscEnv xs
          -- ALL UNQUALIFIED ^

          return $ filterComplsByIdent (cachedLocalCmps ++ unqualCompls)
        else do
          let getQualComplsGhc = maybe (pure Set.empty) (\env -> GM.runLightGhc env getQualifedCompls) hscEnv
          xs <- Set.toList <$> getQualComplsGhc
          setCiTypesForImported hscEnv xs
          -- ALL QUALIFIED ^
      
      debugm $ "~~~~~ comps " ++ show comps

      -- return $ IdeResponseOk $ const completionItems (modNameCompls ++ map mkCompl comps)
      return $ IdeResponseOk $ modNameCompls ++ map mkCompl comps

      -- return $ IdeResponseOk $ modNameCompls ++ map mkModCompl (const cachedLocalCmps (const comps fullPrefix))


getTypeForName :: Name -> IdeM (Maybe Type)
getTypeForName n = do
  hscEnvRef <- ghcSession <$> readMTS
  mhscEnv <- liftIO $ traverse readIORef hscEnvRef
  case mhscEnv of
    Nothing -> return Nothing
    Just hscEnv -> do
      mt <- liftIO $ (Just <$> lookupGlobal hscEnv n)
                        `catch` \(_ :: SomeException) -> return Nothing
      return $ fmap varType $ safeTyThingId =<< mt

-- ---------------------------------------------------------------------

getSymbolsAtPoint :: Uri -> Position -> IdeM (IdeResponse [(Range, Name)])
getSymbolsAtPoint uri pos = pluginGetFile "getSymbolsAtPoint: " uri $ \file -> do
  let noCache = return $ nonExistentCacheErr "getSymbolAtPoint"
  withCachedModule file noCache $
    return . IdeResponseOk . getSymbolsAtPointPure pos

getSymbolsAtPointPure :: Position -> CachedModule -> [(Range,Name)]
getSymbolsAtPointPure pos cm = maybe [] (`getArtifactsAtPos` locMap cm) $ newPosToOld cm pos

symbolFromTypecheckedModule
  :: LocMap
  -> Position
  -> Maybe (Range, Name)
symbolFromTypecheckedModule lm pos =
  case getArtifactsAtPos pos lm of
    (x:_) -> pure x
    []    -> Nothing

-- ---------------------------------------------------------------------

getReferencesInDoc :: Uri -> Position -> IdeM (IdeResponse [J.DocumentHighlight])
getReferencesInDoc uri pos = pluginGetFile "getReferencesInDoc: " uri $ \file -> do
  let noCache = return $ nonExistentCacheErr "getReferencesInDoc"
  withCachedModuleAndData file noCache $
    \cm NMD{inverseNameMap} -> runExceptT $ do
      let lm = locMap cm
          pm = tm_parsed_module $ tcMod cm
          cfile = ml_hs_file $ ms_location $ pm_mod_summary pm
          mpos = newPosToOld cm pos
      case mpos of
        Nothing -> return []
        Just pos' -> fmap concat $
          forM (getArtifactsAtPos pos' lm) $ \(_,name) -> do
              let usages = fromMaybe [] $ Map.lookup name inverseNameMap
                  defn = nameSrcSpan name
                  defnInSameFile =
                    (unpackFS <$> srcSpanFileName_maybe defn) == cfile
                  makeDocHighlight :: SrcSpan -> Maybe J.DocumentHighlight
                  makeDocHighlight spn = do
                    let kind = if spn == defn then J.HkWrite else J.HkRead
                    let
                      foo (Left _) = Nothing
                      foo (Right r) = Just r
                    r <- foo $ srcSpan2Range spn
                    r' <- oldRangeToNew cm r
                    return $ J.DocumentHighlight r' (Just kind)
                  highlights
                    |    isVarOcc (occName name)
                      && defnInSameFile = mapMaybe makeDocHighlight (defn : usages)
                    | otherwise = mapMaybe makeDocHighlight usages
              return highlights

-- ---------------------------------------------------------------------

showQualName :: Outputable a => a -> T.Text
showQualName = T.pack . showGhcQual

showName :: Outputable a => a -> T.Text
showName = T.pack . showGhc

getModule :: DynFlags -> Name -> Maybe (Maybe T.Text,T.Text)
getModule df n = do
  m <- nameModule_maybe n
  let uid = moduleUnitId m
  let pkg = showGhc . packageName <$> lookupPackage df uid
  return (T.pack <$> pkg, T.pack $ moduleNameString $ moduleName m)

-- ---------------------------------------------------------------------

getNewNames :: GhcMonad m => Name -> m [Name]
getNewNames old = do
  let eqModules (Module pk1 mn1) (Module pk2 mn2) = mn1 == mn2 && pk1 == pk2
  gnames <- GHC.getNamesInScope
  let clientModule = GHC.nameModule old
  let clientInscopes = filter (\n -> eqModules clientModule (GHC.nameModule n)) gnames
  let newNames = filter (\n -> showGhcQual n == showGhcQual old) clientInscopes
  return newNames

findDef :: Uri -> Position -> IdeGhcM (IdeResponse [Location])
findDef uri pos = pluginGetFile "findDef: " uri $ \file -> do
  let noCache = return $ nonExistentCacheErr "hare:findDef"
  withCachedModule file noCache $
    \cm -> do
      let rfm = revMap cm
          lm = locMap cm
      case symbolFromTypecheckedModule lm =<< newPosToOld cm pos of
        Nothing -> return $ IdeResponseOk []
        Just pn -> do
          let n = snd pn
          case nameSrcSpan n of
            UnhelpfulSpan _ -> return $ IdeResponseOk []
            realSpan   -> do
              res <- srcSpan2Loc rfm realSpan
              case res of
                Right l@(J.Location luri range) ->
                  case oldRangeToNew cm range of
                    Just r  -> return $ IdeResponseOk [J.Location luri r]
                    Nothing -> return $ IdeResponseOk [l]
                Left x -> do
                  let failure = pure (IdeResponseFail
                                        (IdeError PluginError
                                                  ("hare:findDef" <> ": \"" <> x <> "\"")
                                                  Null))
                  case nameModule_maybe n of
                    Just m -> do
                      let mName = moduleName m
                      b <- GM.unGmlT $ isLoaded mName
                      if b then do
                        mLoc <- GM.unGmlT $ ms_location <$> getModSummary mName
                        case ml_hs_file mLoc of
                          Just fp -> do
                            cfp <- reverseMapFile rfm fp
                            mcm' <- getCachedModule cfp
                            rcm' <- case mcm' of
                              Just cmdl -> do
                                debugm "module already in cache in findDef"
                                return $ Just cmdl
                              Nothing -> do
                                debugm "setting cached module in findDef"
                                _ <- setTypecheckedModule $ filePathToUri cfp
                                getCachedModule cfp
                            case rcm' of
                              Nothing ->
                                return
                                  $ IdeResponseFail
                                  $ IdeError PluginError ("hare:findDef: failed to load module for " <> T.pack cfp) Null
                              Just cm' -> do
                                let modSum = pm_mod_summary $ tm_parsed_module $ tcMod cm'
                                    rfm'   = revMap cm'
                                newNames <- GM.unGmlT $ do
                                  setGhcContext modSum
                                  getNewNames n
                                eithers <- mapM (srcSpan2Loc rfm' . nameSrcSpan) newNames
                                case rights eithers of
                                  (l:_) -> return $ IdeResponseOk [l]
                                  []    -> failure
                          Nothing -> failure
                        else failure
                    Nothing -> failure

-- ---------------------------------------------------------------------


runHareCommand :: String -> RefactGhc [ApplyRefacResult]
                 -> IdeGhcM (IdeResponse WorkspaceEdit)
runHareCommand name cmd = do
     eitherRes <- runHareCommand' cmd
     case eitherRes of
       Left err ->
         pure (IdeResponseFail
                 (IdeError PluginError
                           (T.pack $ name <> ": \"" <> err <> "\"")
                           Null))
       Right res -> do
            let changes = getRefactorResult res
            refactRes <- makeRefactorResult changes
            pure (IdeResponseOk refactRes)

-- ---------------------------------------------------------------------

runHareCommand' :: RefactGhc a
                 -> IdeGhcM (Either String a)
runHareCommand' cmd =
  do let initialState =
           -- TODO: Make this a command line flag
           RefSt {rsSettings = defaultSettings
           -- RefSt {rsSettings = logSettings
                 ,rsUniqState = 1
                 ,rsSrcSpanCol = 1
                 ,rsFlags = RefFlags False
                 ,rsStorage = StorageNone
                 ,rsCurrentTarget = Nothing
                 ,rsModule = Nothing}
     let cmd' = unRefactGhc cmd
         embeddedCmd =
           GM.unGmlT $
           hoist (liftIO . flip evalStateT initialState)
                 (GM.GmlT cmd')
         handlers
           :: Applicative m
           => [GM.GHandler m (Either String a)]
         handlers =
           [GM.GHandler (\(ErrorCall e) -> pure (Left e))
           ,GM.GHandler (\(err :: GM.GhcModError) -> pure (Left (show err)))]
     fmap Right embeddedCmd `GM.gcatches` handlers

-- ---------------------------------------------------------------------
-- | This is like hoist from the mmorph package, but build on
-- `MonadTransControl` since we don’t have an `MFunctor` instance.
hoist
  :: (MonadTransControl t,Monad (t m'),Monad m',Monad m)
  => (forall b. m b -> m' b) -> t m a -> t m' a
hoist f a =
  liftWith (\run ->
              let b = run a
                  c = f b
              in pure c) >>=
  restoreT
