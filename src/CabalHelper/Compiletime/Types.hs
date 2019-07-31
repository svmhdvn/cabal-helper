-- cabal-helper: Simple interface to Cabal's configuration state
-- Copyright (C) 2015-2018  Daniel Gröber <cabal-helper@dxld.at>
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.

{-# LANGUAGE DeriveGeneric, DeriveDataTypeable, DefaultSignatures,
  StandaloneDeriving, GADTs, DataKinds, KindSignatures, RankNTypes, PolyKinds #-}

{-|
Module      : CabalHelper.Compiletime.Types
Description : Types used throughout
License     : GPL-3
-}

module CabalHelper.Compiletime.Types where

import Cabal.Plan
  ( PlanJson )
import Data.ByteString (ByteString)
import Data.IORef
import Data.Version
import Data.Typeable
import GHC.Generics
import System.Posix.Types
import CabalHelper.Compiletime.Types.RelativePath
import CabalHelper.Shared.InterfaceTypes

import Data.List.NonEmpty (NonEmpty)
--import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
--import qualified Data.Map.Strict as Strict

-- | The kind of project being managed by a 'QueryEnv' (pun intended). Used
-- as a phantom-type variable throughout to make the project type being
-- passed into various functions correspond to the correct implementation.
data ProjType
    = V1    -- ^ @cabal v1-build@ project.
    | V2    -- ^ @cabal v2-build@ project.
    | Stack -- ^ @stack@ project.
      deriving (Eq, Ord, Show, Read)

-- | A "singleton" datatype for 'ProjType' which allows us to establish a
-- correspondence between a runtime representation of 'ProjType' to the
-- compile-time value at the type level.
--
-- If you just want to know the runtime 'ProjType' use 'demoteSProjType' to
-- convert to that.
data SProjType pt where
    SCabal :: !(SCabalProjType pt) -> SProjType pt
    SStack :: SProjType 'Stack

deriving instance Show (SProjType pt)

-- | This is a singleton, like 'SProjType', but restricted to just the
-- Cabal project types. We use this to restrict some functions which don't
-- make sense for Stack to just the Cabal project types.
data SCabalProjType pt where
    SCV1 :: SCabalProjType 'V1
    SCV2 :: SCabalProjType 'V2

deriving instance Show (SCabalProjType pt)

demoteSProjType :: SProjType pt -> ProjType
demoteSProjType (SCabal SCV1) = V1
demoteSProjType (SCabal SCV2) = V2
demoteSProjType SStack = Stack

-- | Location of a project context. Usually a project's top-level source
-- code directory or a project type specific config file.
--
-- To find any recognized default project contexts in a given directory
-- use 'Distribution.Helper.Discover.findProjects'.
--
-- Build tools usually allow the user to specify the location of their
-- project config files manually, so we also support passing this path here
-- with the @*File@ constructors.
--
-- === Correspondence with Project Source Directory
--
-- Note that the project's source directory does not necessarily correspond
-- to the directory containing the project config file, though in some
-- cases it does.
--
-- For example cabal-V2 allows the @cabal.project@ file to be positively
-- anywhere in the filesystem when specified via the @--cabal-project@
-- command-line flag, corresponding to the 'ProjLocV2File' constructor
-- here. This config file can then refer to package directories with
-- absolute paths in the @packages:@ declaration.
--
-- Hence it isn't actually possible to find the whole project's toplevel
-- source directory given just a 'ProjLoc'. However the packages within a
-- project have a well defined source directory.
--
-- Unfortunately we do not expose the concept of a "package" in the API to
-- abstract the differences between the project types. Instead each 'Unit'
-- (which is conceptually part of a "package") carries the corresponding
-- package source directory in 'uPackageDir'. Together with a 'Unit' query
-- such as 'projectUnits' you can thus get the source directory for each
-- unit.
--
-- If you need to present this in a per-package view rather than a per-unit
-- view you should be able to use the source directory as a key to
-- determine which units to group into a package.
data ProjLoc (pt :: ProjType) where
    -- | A fully specified @cabal v1-build@ project context. Here you can
    -- specify both the path to the @.cabal@ file and the source directory
    -- of the package. The cabal file path corresponds to the
    -- @--cabal-file=PATH@ flag on the @cabal@ command line.
    --
    -- Note that More than one such files existing in a package directory
    -- is a user error and cabal might still complain about that but we
    -- won't.
    --
    -- Also note that for this project type the concepts of project and
    -- package coincide.
    ProjLocV1CabalFile :: { plCabalFile :: !FilePath, plPackageDir :: !FilePath } -> ProjLoc 'V1

    -- | A @cabal v1-build@ project context. Essentially the same as
    -- 'ProjLocV1CabalFile' but this will dynamically search for the cabal
    -- file for you as cabal-install does by default.
    --
    -- If more than one @.cabal@ file exists in the given directory we will
    -- shamelessly throw a obscure exception when using this in the API so
    -- prefer 'ProjLocV1CabalFile' if you don't want that to happen. This
    -- mainly exists for easy upgrading from the @cabal-helper-0.8@ series.
    ProjLocV1Dir :: { plPackageDir :: !FilePath } -> ProjLoc 'V1

    -- | A @cabal v2-build@ project context. The path to the
    -- @cabal.project@ file, though you can call it whatever you like. This
    -- configuration file then points to the packages that make up this
    -- project. This corresponds to the @--cabal-project=PATH@ flag on the
    -- @cabal@ command line.
    ProjLocV2File    :: { plCabalProjectFile :: !FilePath } -> ProjLoc 'V2

    -- | This is equivalent to 'ProjLocV2File' but using the default
    -- @cabal.project@ file name.
    ProjLocV2Dir     :: { plV2Dir :: !FilePath } -> ProjLoc 'V2

    -- | A @stack@ project context. Specify the path to the @stack.yaml@
    -- file here. This configuration file then points to the packages that
    -- make up this project. Corresponds to @stack@'s @--stack-yaml=PATH@
    -- command line flag if different from the default name, @stack.yaml@.
    ProjLocStackYaml :: { plStackYaml :: !FilePath } -> ProjLoc 'Stack

deriving instance Show (ProjLoc pt)

plV1Dir :: ProjLoc 'V1 -> FilePath
plV1Dir ProjLocV1CabalFile {plPackageDir} = plPackageDir
plV1Dir ProjLocV1Dir {plPackageDir} = plPackageDir

projTypeOfProjLoc :: ProjLoc pt -> SProjType pt
projTypeOfProjLoc ProjLocV1CabalFile{} = SCabal SCV1
projTypeOfProjLoc ProjLocV1Dir{}       = SCabal SCV1
projTypeOfProjLoc ProjLocV2File{}      = SCabal SCV2
projTypeOfProjLoc ProjLocV2Dir{}       = SCabal SCV2
projTypeOfProjLoc ProjLocStackYaml{}   = SStack

-- | A build directory for a certain project type. The @pt@ type variable
-- must be compatible with the 'ProjLoc' used. This is enforced by the type
-- system so you can't get this wrong.
data DistDir (pt :: ProjType) where
    -- | A build-directory for cabal, aka. dist-dir in Cabal
    -- terminology. 'SCabalProjType' specifies whether we should use
    -- /v2-build/ or /v1-build/. This choice must correspond to
    -- 'ProjLoc' \'s project type.
    DistDirCabal :: !(SCabalProjType pt) -> !FilePath -> DistDir pt

    -- | A build-directory for stack, aka. /work-dir/. Optionally override
    -- Stack's /work-dir/. If you just want to use Stack's default set to
    -- @Nothing@
    DistDirStack :: !(Maybe RelativePath) -> DistDir 'Stack

deriving instance Show (DistDir pt)

projTypeOfDistDir :: DistDir pt -> SProjType pt
projTypeOfDistDir (DistDirCabal pt _) = SCabal pt
projTypeOfDistDir DistDirStack{} = SStack

-- | General purpose existential wrapper. Useful for hiding a phantom type
-- argument.
--
-- Say you have:
--
-- @
-- {-\# LANGUAGE DataKinds, GADTS \#-}
-- data K = A | B | ...
-- data Q k where
--   QA :: ... -> Q 'A
--   QB :: ... -> Q 'B
-- @
--
-- and you want a list of @Q@. You can use @Ex@ to hide the phantom type
-- argument and recover it later by matching on the GADT constructors:
--
-- @
-- qa :: Q A
-- qa = QA
--
-- qb :: Q B
-- qb = QB
--
-- mylist :: [Ex Q]
-- mylist = [Ex qa, Ex qb]
-- @
data Ex a = forall x. Ex (a x)

-- | Environment for running a 'Query'. The constructor is not exposed in the
-- API to allow extending it with more fields without breaking user code.
--
-- To create a 'QueryEnv' use the 'mkQueryEnv' smart constructor instead. The
-- field accessors are exported and may be used to override the defaults filled
-- in by 'mkQueryEnv'. See below.
--
-- Note that this environment contains an 'IORef' used as a cache. If you want
-- to take advantage of this you should not simply discard the value returned by
-- the smart constructor after one use.
--
-- If you do not wish to use the built-in caching feel free to discard the
-- 'QueryEnv' value though.
type QueryEnv = QueryEnvI QueryCache

data QueryEnvI c (pt :: ProjType) = QueryEnv
    { qeReadProcess :: !ReadProcessWithCwd
    -- ^ Field accessor for 'QueryEnv'. Function used to to start
    -- processes. Useful if you need to, for example, redirect standard error
    -- output of programs started by cabal-helper.

    , qeCallProcess :: !(CallProcessWithCwd ())

    , qePrograms     :: !Programs
    -- ^ Field accessor for 'QueryEnv'.

    , qeCompPrograms :: !CompPrograms
    -- ^ Field accessor for 'QueryEnv'.

    , qeProjLoc      :: !(ProjLoc pt)
    -- ^ Field accessor for 'QueryEnv'. Defines path to the project directory,
    -- i.e. a directory containing a @cabal.project@ file

    , qeDistDir      :: !(DistDir pt)
    -- ^ Field accessor for 'QueryEnv'. Defines path to the @dist/@ or
    -- @dist-newstyle/@ directory, aka. /builddir/ in Cabal terminology.

    , qeCacheRef     :: !(IORef (c pt))
    -- ^ Cache for query results, only accessible when type parameter @c@ is
    -- instantiated with 'QueryCache'. This is the case wherever the type alias
    -- 'QueryEnv' is used.
    }

type ReadProcessWithCwd   = String -> CallProcessWithCwd String
type CallProcessWithCwd a = Maybe FilePath -> FilePath -> [String] -> IO a

data QueryCache pt = QueryCache
    { qcProjInfo  :: !(Maybe (ProjInfo pt))
    , qcUnitInfos :: !(Map DistDirLib UnitInfo)
    }

newtype DistDirLib = DistDirLib FilePath
    deriving (Eq, Ord, Read, Show)

-- | A 'Unit' is essentially a "build target". It is used to refer to a set
-- of components (exes, libs, tests etc.) which are managed by a certain
-- instance of the Cabal build-system[1]. We may get information on the
-- components in a unit by retriving the corresponding 'UnitInfo'.
--
-- \[1]: No I'm not talking about the cabal-install /build-tool/, I'm
-- talking about the Cabal /build-system/. Note the distinction. Both
-- cabal-install and Stack use the Cabal build-system (aka @lib:Cabal@)
-- underneath.
--
-- Note that a 'Unit' value is only valid within the 'QueryEnv' context it
-- was created in. However this is not enforced by the API.
data Unit pt = Unit
    { uUnitId      :: !UnitId
    , uPackageDir  :: !FilePath
    , uCabalFile   :: !CabalFile
    , uDistDir     :: !DistDirLib
    , uImpl        :: !(UnitImpl pt)
    } deriving (Show)

data UnitImpl pt where
  UnitImplV1 :: UnitImpl 'V1

  UnitImplV2 ::
    { uiV2ComponentNames :: ![ChComponentName]
    , uiV2Components     :: ![String]
    } -> UnitImpl 'V2

  UnitImplStack :: UnitImpl 'Stack

deriving instance Show (UnitImpl pt)

-- | This returns the component a 'Unit' corresponds to. This information is
-- only available if the correspondence happens to be unique and known before
-- querying setup-config for the respective project type. Currently this only
-- applies to @pt=@'V2'.
--
-- This is intended to be used as an optimization, to allow reducing the number
-- of helper invocations for clients that don't need to know the entire project
-- structure.
uComponentName :: Unit pt -> Maybe ChComponentName
uComponentName Unit { uImpl=UnitImplV2 { uiV2ComponentNames=[comp] } } =
    Just comp
uComponentName _ =
    Nothing

-- | The @setup-config@ header. Note that Cabal writes all the package names in
-- the header using 'Data.ByteString.Char8' and hence all characters are
-- truncated from Unicode codepoints to 8-bit Latin-1.
--
-- We can be fairly confident that 'uhSetupId' and 'uhCompilerId' won\'t have
-- names that cause trouble here so it's ok to look at them but user packages
-- are free to have any unicode name.
data UnitHeader = UnitHeader
    { uhBrokenPackageId  :: !(ByteString, Version)
      -- ^ Name and version of the source package. Don't use this, it's broken
      -- when the package name contains Unicode characters. See 'uiPackageId'
      -- instead. Note: This was fixed by hvr in Cabal HEAD actually.
    , uhSetupId    :: !(ByteString, Version)
      -- ^ Name and version of the @Setup.hs@ implementation. We expect
      -- @"Cabal"@ here, naturally.
    , uhCompilerId :: !(ByteString, Version)
      -- ^ Name and version of the compiler that was used to build
      -- Setup.hs. WARNING: This does not identify the GHC version the project
      -- is configured to use!
    } deriving (Eq, Ord, Read, Show)

newtype UnitId = UnitId String
    deriving (Eq, Ord, Read, Show)

-- | The information extracted from a 'Unit'\'s on-disk configuration cache.
data UnitInfo = UnitInfo
    { uiUnitId                :: !UnitId
    -- ^ A unique identifier of this unit within the originating project.

    , uiPackageId             :: !(String, Version)
    -- ^ The package-name and version this unit belongs to.

    , uiComponents            :: !(Map ChComponentName ChComponentInfo)
    -- ^ The components of the unit: libraries, executables, test-suites,
    -- benchmarks and so on.

    , uiCompilerId            :: !(String, Version)
    -- ^ The version of GHC the unit is configured to use

    , uiPackageDbStack        :: !([ChPkgDb])
    -- ^ List of package databases to use.

    , uiPackageFlags          :: !([(String, Bool)])
    -- ^ Flag definitions from cabal file

    , uiConfigFlags           :: ![(String, Bool)]
    -- ^ Flag assignments from active configuration

    , uiNonDefaultConfigFlags :: ![(String, Bool)]
    -- ^ Flag assignments from setup-config which differ from the default
    -- setting. This can also include flags which cabal decided to modify,
    -- i.e. don't rely on these being the flags set by the user directly.

    , uiModTimes              :: !UnitModTimes
    -- ^ Key for cache invalidation. When this is not equal to the value
    -- returned by 'getUnitModTimes' this 'UnitInfo' is considered invalid.
    } deriving (Eq, Ord, Read, Show)

-- | Files relevant to the project-scope configuration. We gather them here so
-- we can refer to their paths conveniently throughout the code. These files are
-- not necessarily guaranteed to even exist.
data ProjConf pt where
  ProjConfV1 ::
    { pcV1CabalFile :: !FilePath
    } -> ProjConf 'V1

  ProjConfV2 ::
    { pcV2CabalProjFile       :: !FilePath
    , pcV2CabalProjLocalFile  :: !FilePath
    , pcV2CabalProjFreezeFile :: !FilePath
    } -> ProjConf 'V2

  ProjConfStack ::
    { pcStackYaml :: !FilePath
    } -> ProjConf 'Stack

-- This is supposed to be opaque, as it's only meant to be used only for cache
-- invalidation.
newtype ProjConfModTimes = ProjConfModTimes [(FilePath, EpochTime)]
    deriving (Eq, Show)

-- | Project-scope information cache.
data ProjInfo pt = ProjInfo
  { piCabalVersion     :: !Version
  , piUnits            :: !(NonEmpty (Unit pt))
  , piImpl             :: !(ProjInfoImpl pt)
  , piProjConfModTimes :: !ProjConfModTimes
  -- ^ Key for cache invalidation. When this is not equal to the return
  -- value of 'getProjConfModTime' this 'ProjInfo' is considered invalid.
  } deriving (Show)

data ProjInfoImpl pt where
  ProjInfoV1 ::
    { piV1SetupHeader :: !UnitHeader
    } -> ProjInfoImpl 'V1

  ProjInfoV2 ::
    { piV2Plan        :: !PlanJson
    , piV2PlanModTime :: !EpochTime
    , piV2CompilerId  :: !(String, Version)
    } -> ProjInfoImpl 'V2

  ProjInfoStack ::
    { piStackProjPaths :: !StackProjPaths
    } -> ProjInfoImpl 'Stack

instance Show (ProjInfoImpl pt) where
    show ProjInfoV1 {..} = concat
      [ "ProjInfoV1 {"
      , "piV1SetupHeader = ", show piV1SetupHeader, ", "
      , "}"
      ]
    show ProjInfoV2 {..} = concat
      [ "ProjInfoV2 {"
      , "piV2Plan = ", show piV2Plan, ", "
      , "piV2PlanModTime = ", show piV2PlanModTime, ", "
      , "piV2CompilerId = ", show piV2CompilerId
      , "}"
      ]
    show ProjInfoStack {..} = concat
      [ "ProjInfoStack {"
      , "piStackProjPaths = ", show piStackProjPaths
      , "}"
      ]

data UnitModTimes = UnitModTimes
    { umtPkgYaml     :: !(Maybe (FilePath, EpochTime))
    , umtCabalFile   :: !(FilePath, EpochTime)
    , umtSetupConfig :: !(Maybe (FilePath, EpochTime))
    } deriving (Eq, Ord, Read, Show)

newtype CabalFile = CabalFile FilePath
    deriving (Show)

data StackProjPaths = StackProjPaths
    { sppGlobalPkgDb :: !PackageDbDir
    , sppSnapPkgDb   :: !PackageDbDir
    , sppLocalPkgDb  :: !PackageDbDir
    , sppCompExe     :: !FilePath
    } deriving (Show)


-- Beware: GHC 8.0.2 doesn't like these being recursively defined for some
-- reason so just keep them unrolled.
type Verbose = (?verbose :: Word -> Bool)
type Env     = ( ?cprogs :: CompPrograms
               , ?progs :: Programs
               , ?verbose :: Word -> Bool)
type Progs   = (?cprogs :: CompPrograms, ?progs :: Programs)
type CProgs  = (?cprogs :: CompPrograms)

-- | Configurable paths to various programs we use.
data Programs = Programs
    { cabalProgram    :: !FilePath
      -- ^ The path to the @cabal@ program.
    , cabalArgsBefore :: ![String]
    , cabalArgsAfter  :: ![String]

    , stackProgram    :: !FilePath
      -- ^ The path to the @stack@ program.
    , stackArgsBefore :: ![String]
    , stackArgsAfter  :: ![String]
    } deriving (Eq, Ord, Show, Read, Generic, Typeable)

-- | Configurable paths to programs only used during helper compilation.
data CompPrograms = CompPrograms
    { ghcProgram    :: !FilePath
    -- ^ The path to the @ghc@ program.

    , ghcPkgProgram :: !FilePath
    -- ^ The path to the @ghc-pkg@ program. If not changed it will be derived
    -- from the path to 'ghcProgram'.
    } deriving (Eq, Ord, Show, Read, Generic, Typeable)

-- | By default all programs use their unqualified names, i.e. they will be
-- searched for on @PATH@.
defaultPrograms :: Programs
defaultPrograms = Programs "cabal" [] []  "stack" [] []

defaultCompPrograms :: CompPrograms
defaultCompPrograms = CompPrograms "ghc" "ghc-pkg"

data CompileOptions = CompileOptions
    { oVerbose       :: Bool
    , oCabalPkgDb    :: Maybe PackageDbDir
    , oCabalVersion  :: Maybe Version
    , oPrograms      :: Programs
    }

oCabalProgram :: Env => FilePath
oCabalProgram = cabalProgram ?progs

defaultCompileOptions :: CompileOptions
defaultCompileOptions =
    CompileOptions False Nothing Nothing defaultPrograms

newtype PackageDbDir = PackageDbDir { unPackageDbDir :: FilePath }
    deriving (Show)
newtype PackageEnvFile = PackageEnvFile { unPackageEnvFile :: FilePath }
    deriving (Show)
