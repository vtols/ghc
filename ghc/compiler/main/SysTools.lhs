-----------------------------------------------------------------------------
--
-- (c) The University of Glasgow 2001-2003
--
-- Access to system tools: gcc, cp, rm etc
--
-----------------------------------------------------------------------------

\begin{code}
module SysTools (
	-- Initialisation
	initSysTools,

	getTopDir,		-- IO String	-- The value of $topdir
	getPackageConfigPath,	-- IO String	-- Where package.conf is
        getUsageMsgPaths,       -- IO (String,String)

	-- Interface to system tools
	runUnlit, runCpp, runCc, -- [Option] -> IO ()
	runPp,                   -- [Option] -> IO ()
	runMangle, runSplit,	 -- [Option] -> IO ()
	runAs, runLink,		 -- [Option] -> IO ()
	runMkDLL,

	touch,			-- String -> String -> IO ()
	copy,			-- String -> String -> String -> IO ()
	normalisePath,          -- FilePath -> FilePath
	
	-- Temporary-file management
	setTmpDir,
	newTempName,
	cleanTempFiles, cleanTempFilesExcept,
	addFilesToClean,

	-- System interface
	system, 		-- String -> IO ExitCode

	-- Misc
	getSysMan,		-- IO String	Parallel system only
	
	Option(..)

 ) where

#include "HsVersions.h"

import DriverPhases     ( isHaskellUserSrcFilename )
import Config
import Outputable
import ErrUtils		( putMsg, debugTraceMsg, showPass, Severity(..), Messages )
import Panic		( GhcException(..) )
import Util		( Suffix, global, notNull, consIORef, joinFileName,
			  normalisePath, pgmPath, platformPath, joinFileExt )
import DynFlags		( DynFlags(..), DynFlag(..), dopt, Option(..),
			  setTmpDir, defaultDynFlags )

import EXCEPTION	( throwDyn )
import DATA_IOREF	( IORef, readIORef, writeIORef )
import DATA_INT
    
import Monad		( when, unless )
import System		( ExitCode(..), getEnv, system )
import IO		( try, catch,
			  openFile, hPutStr, hClose, hFlush, IOMode(..), 
			  stderr, ioError, isDoesNotExistError )
import Directory	( doesFileExist, removeFile )
import List             ( partition )

-- GHC <= 4.08 didn't have rawSystem, and runs into problems with long command
-- lines on mingw32, so we disallow it now.
#if __GLASGOW_HASKELL__ < 500
#error GHC >= 5.00 is required for bootstrapping GHC
#endif

#ifndef mingw32_HOST_OS
#if __GLASGOW_HASKELL__ > 504
import qualified System.Posix.Internals
#else
import qualified Posix
#endif
#else /* Must be Win32 */
import List		( isPrefixOf )
import Util		( dropList )
import Foreign
import CString		( CString, peekCString )
#endif

#if __GLASGOW_HASKELL__ < 603
-- rawSystem comes from libghccompat.a in stage1
import Compat.RawSystem	( rawSystem )
import GHC.IOBase       ( IOErrorType(..) ) 
import System.IO.Error  ( ioeGetErrorType )
#else
import System.Process	( runInteractiveProcess, getProcessExitCode )
import System.IO        ( hSetBuffering, hGetLine, BufferMode(..) )
import Control.Concurrent( forkIO, newChan, readChan, writeChan )
import Text.Regex
import Data.Char        ( isSpace )
import FastString       ( mkFastString )
import SrcLoc           ( SrcLoc, mkSrcLoc, noSrcSpan, mkSrcSpan )
#endif
\end{code}


		The configuration story
		~~~~~~~~~~~~~~~~~~~~~~~

GHC needs various support files (library packages, RTS etc), plus
various auxiliary programs (cp, gcc, etc).  It finds these in one
of two places:

* When running as an *installed program*, GHC finds most of this support
  stuff in the installed library tree.  The path to this tree is passed
  to GHC via the -B flag, and given to initSysTools .

* When running *in-place* in a build tree, GHC finds most of this support
  stuff in the build tree.  The path to the build tree is, again passed
  to GHC via -B. 

GHC tells which of the two is the case by seeing whether package.conf
is in TopDir [installed] or in TopDir/ghc/driver [inplace] (what a hack).


SysTools.initSysProgs figures out exactly where all the auxiliary programs
are, and initialises mutable variables to make it easy to call them.
To to this, it makes use of definitions in Config.hs, which is a Haskell
file containing variables whose value is figured out by the build system.

Config.hs contains two sorts of things

  cGCC, 	The *names* of the programs
  cCPP		  e.g.  cGCC = gcc
  cUNLIT	        cCPP = gcc -E
  etc		They do *not* include paths
				

  cUNLIT_DIR_REL   The *path* to the directory containing unlit, split etc
  cSPLIT_DIR_REL   *relative* to the root of the build tree,
		   for use when running *in-place* in a build tree (only)
		


---------------------------------------------
NOTES for an ALTERNATIVE scheme (i.e *not* what is currently implemented):

Another hair-brained scheme for simplifying the current tool location
nightmare in GHC: Simon originally suggested using another
configuration file along the lines of GCC's specs file - which is fine
except that it means adding code to read yet another configuration
file.  What I didn't notice is that the current package.conf is
general enough to do this:

Package
    {name = "tools",    import_dirs = [],  source_dirs = [],
     library_dirs = [], hs_libraries = [], extra_libraries = [],
     include_dirs = [], c_includes = [],   package_deps = [],
     extra_ghc_opts = ["-pgmc/usr/bin/gcc","-pgml${topdir}/bin/unlit", ... etc.],
     extra_cc_opts = [], extra_ld_opts = []}

Which would have the advantage that we get to collect together in one
place the path-specific package stuff with the path-specific tool
stuff.
		End of NOTES
---------------------------------------------


%************************************************************************
%*									*
\subsection{Global variables to contain system programs}
%*									*
%************************************************************************

All these pathnames are maintained IN THE NATIVE FORMAT OF THE HOST MACHINE.
(See remarks under pathnames below)

\begin{code}
GLOBAL_VAR(v_Pgm_T,    error "pgm_T",    String)	-- touch
GLOBAL_VAR(v_Pgm_CP,   error "pgm_CP", 	 String)	-- cp

GLOBAL_VAR(v_Path_package_config, error "path_package_config", String)
GLOBAL_VAR(v_Path_usages,  	  error "ghc_usage.txt",       (String,String))

GLOBAL_VAR(v_TopDir,	error "TopDir",	String)		-- -B<dir>

-- Parallel system only
GLOBAL_VAR(v_Pgm_sysman, error "pgm_sysman", String)	-- system manager

-- ways to get at some of these variables from outside this module
getPackageConfigPath = readIORef v_Path_package_config
getTopDir	     = readIORef v_TopDir
\end{code}


%************************************************************************
%*									*
\subsection{Initialisation}
%*									*
%************************************************************************

\begin{code}
initSysTools :: [String]	-- Command-line arguments starting "-B"

	     -> DynFlags
	     -> IO DynFlags	-- Set all the mutable variables above, holding 
				--	(a) the system programs
				--	(b) the package-config file
				--	(c) the GHC usage message


initSysTools minusB_args dflags
  = do  { (am_installed, top_dir) <- findTopDir minusB_args
	; writeIORef v_TopDir top_dir
		-- top_dir
		-- 	for "installed" this is the root of GHC's support files
		--	for "in-place" it is the root of the build tree
		-- NB: top_dir is assumed to be in standard Unix format '/' separated

	; let installed, installed_bin :: FilePath -> FilePath
              installed_bin pgm   =  pgmPath top_dir pgm
	      installed     file  =  pgmPath top_dir file
	      inplace dir   pgm   =  pgmPath (top_dir `joinFileName` 
						cPROJECT_DIR `joinFileName` dir) pgm

	; let pkgconfig_path
		| am_installed = installed "package.conf"
		| otherwise    = inplace cGHC_DRIVER_DIR_REL "package.conf.inplace"

	      ghc_usage_msg_path
		| am_installed = installed "ghc-usage.txt"
		| otherwise    = inplace cGHC_DRIVER_DIR_REL "ghc-usage.txt"

	      ghci_usage_msg_path
		| am_installed = installed "ghci-usage.txt"
		| otherwise    = inplace cGHC_DRIVER_DIR_REL "ghci-usage.txt"

		-- For all systems, unlit, split, mangle are GHC utilities
		-- architecture-specific stuff is done when building Config.hs
	      unlit_path
		| am_installed = installed_bin cGHC_UNLIT_PGM
		| otherwise    = inplace cGHC_UNLIT_DIR_REL cGHC_UNLIT_PGM

		-- split and mangle are Perl scripts
	      split_script
		| am_installed = installed_bin cGHC_SPLIT_PGM
		| otherwise    = inplace cGHC_SPLIT_DIR_REL cGHC_SPLIT_PGM

	      mangle_script
		| am_installed = installed_bin cGHC_MANGLER_PGM
		| otherwise    = inplace cGHC_MANGLER_DIR_REL cGHC_MANGLER_PGM

	; let dflags0 = defaultDynFlags
#ifndef mingw32_HOST_OS
	-- check whether TMPDIR is set in the environment
	; e_tmpdir <- IO.try (getEnv "TMPDIR") -- fails if not set
#else
	  -- On Win32, consult GetTempPath() for a temp dir.
	  --  => it first tries TMP, TEMP, then finally the
	  --   Windows directory(!). The directory is in short-path
	  --   form.
	; e_tmpdir <- 
            IO.try (do
	        let len = (2048::Int)
		buf  <- mallocArray len
		ret  <- getTempPath len buf
		if ret == 0 then do
		      -- failed, consult TMPDIR.
 	             free buf
		     getEnv "TMPDIR"
		  else do
		     s <- peekCString buf
		     free buf
		     return s)
#endif
        ; let dflags1 = case e_tmpdir of
			  Left _  -> dflags0
			  Right d -> setTmpDir d dflags0

	-- Check that the package config exists
	; config_exists <- doesFileExist pkgconfig_path
	; when (not config_exists) $
	     throwDyn (InstallationError 
		         ("Can't find package.conf as " ++ pkgconfig_path))

#if defined(mingw32_HOST_OS)
	--		WINDOWS-SPECIFIC STUFF
	-- On Windows, gcc and friends are distributed with GHC,
	-- 	so when "installed" we look in TopDir/bin
	-- When "in-place" we look wherever the build-time configure 
	--	script found them
	-- When "install" we tell gcc where its specs file + exes are (-B)
	--	and also some places to pick up include files.  We need
	--	to be careful to put all necessary exes in the -B place
	--	(as, ld, cc1, etc) since if they don't get found there, gcc
	--	then tries to run unadorned "as", "ld", etc, and will
	--	pick up whatever happens to be lying around in the path,
	--	possibly including those from a cygwin install on the target,
	--	which is exactly what we're trying to avoid.
	; let gcc_b_arg = Option ("-B" ++ installed "gcc-lib/")
	      (gcc_prog,gcc_args)
		| am_installed = (installed_bin "gcc", [gcc_b_arg])
		| otherwise    = (cGCC, [])
		-- The trailing "/" is absolutely essential; gcc seems
		-- to construct file names simply by concatenating to
		-- this -B path with no extra slash We use "/" rather
		-- than "\\" because otherwise "\\\" is mangled
		-- later on; although gcc_args are in NATIVE format,
		-- gcc can cope
		--	(see comments with declarations of global variables)
		--
		-- The quotes round the -B argument are in case TopDir
		-- has spaces in it

	      perl_path | am_installed = installed_bin cGHC_PERL
		        | otherwise    = cGHC_PERL

	-- 'touch' is a GHC util for Windows, and similarly unlit, mangle
	; let touch_path  | am_installed = installed_bin cGHC_TOUCHY_PGM
		       	  | otherwise    = inplace cGHC_TOUCHY_DIR_REL cGHC_TOUCHY_PGM

	-- On Win32 we don't want to rely on #!/bin/perl, so we prepend 
	-- a call to Perl to get the invocation of split and mangle
	; let (split_prog,  split_args)  = (perl_path, [Option split_script])
	      (mangle_prog, mangle_args) = (perl_path, [Option mangle_script])

	; let (mkdll_prog, mkdll_args)
	        | am_installed = 
		    (pgmPath (installed "gcc-lib/") cMKDLL,
		     [ Option "--dlltool-name",
		       Option (pgmPath (installed "gcc-lib/") "dlltool"),
		       Option "--driver-name",
		       Option gcc_prog, gcc_b_arg ])
		| otherwise    = (cMKDLL, [])
#else
	--		UNIX-SPECIFIC STUFF
	-- On Unix, the "standard" tools are assumed to be
	-- in the same place whether we are running "in-place" or "installed"
	-- That place is wherever the build-time configure script found them.
	; let   gcc_prog   = cGCC
		gcc_args   = []
		touch_path = "touch"
		mkdll_prog = panic "Can't build DLLs on a non-Win32 system"
		mkdll_args = []

	-- On Unix, scripts are invoked using the '#!' method.  Binary
	-- installations of GHC on Unix place the correct line on the front
	-- of the script at installation time, so we don't want to wire-in
	-- our knowledge of $(PERL) on the host system here.
	; let (split_prog,  split_args)  = (split_script,  [])
	      (mangle_prog, mangle_args) = (mangle_script, [])
#endif

	-- cpp is derived from gcc on all platforms
        -- HACK, see setPgmP below. We keep 'words' here to remember to fix
        -- Config.hs one day.
        ; let cpp_path  = (gcc_prog, gcc_args ++ 
			   (Option "-E"):(map Option (words cRAWCPP_FLAGS)))

	-- For all systems, copy and remove are provided by the host
	-- system; architecture-specific stuff is done when building Config.hs
	; let	cp_path = cGHC_CP
	
	-- Other things being equal, as and ld are simply gcc
	; let	(as_prog,as_args)  = (gcc_prog,gcc_args)
		(ld_prog,ld_args)  = (gcc_prog,gcc_args)

	-- Initialise the global vars
	; writeIORef v_Path_package_config pkgconfig_path
	; writeIORef v_Path_usages 	   (ghc_usage_msg_path,
					    ghci_usage_msg_path)

	; writeIORef v_Pgm_sysman	   (top_dir ++ "/ghc/rts/parallel/SysMan")
		-- Hans: this isn't right in general, but you can 
		-- elaborate it in the same way as the others

	; writeIORef v_Pgm_T   	 	   touch_path
	; writeIORef v_Pgm_CP  	 	   cp_path

	; return dflags1{
			pgm_L	= unlit_path,
			pgm_P	= cpp_path,
			pgm_F	= "",
			pgm_c	= (gcc_prog,gcc_args),
			pgm_m	= (mangle_prog,mangle_args),
			pgm_s   = (split_prog,split_args),
			pgm_a   = (as_prog,as_args),
			pgm_l	= (ld_prog,ld_args),
			pgm_dll = (mkdll_prog,mkdll_args) }
	}

#if defined(mingw32_HOST_OS)
foreign import stdcall unsafe "GetTempPathA" getTempPath :: Int -> CString -> IO Int32
#endif
\end{code}

\begin{code}
-- Find TopDir
-- 	for "installed" this is the root of GHC's support files
--	for "in-place" it is the root of the build tree
--
-- Plan of action:
-- 1. Set proto_top_dir
-- 	a) look for (the last) -B flag, and use it
--	b) if there are no -B flags, get the directory 
--	   where GHC is running (only on Windows)
--
-- 2. If package.conf exists in proto_top_dir, we are running
--	installed; and TopDir = proto_top_dir
--
-- 3. Otherwise we are running in-place, so
--	proto_top_dir will be /...stuff.../ghc/compiler
--	Set TopDir to /...stuff..., which is the root of the build tree
--
-- This is very gruesome indeed

findTopDir :: [String]
	  -> IO (Bool, 		-- True <=> am installed, False <=> in-place
	         String)	-- TopDir (in Unix format '/' separated)

findTopDir minusbs
  = do { top_dir <- get_proto
        -- Discover whether we're running in a build tree or in an installation,
	-- by looking for the package configuration file.
       ; am_installed <- doesFileExist (top_dir `joinFileName` "package.conf")

       ; return (am_installed, top_dir)
       }
  where
    -- get_proto returns a Unix-format path (relying on getBaseDir to do so too)
    get_proto | notNull minusbs
	      = return (normalisePath (drop 2 (last minusbs)))	-- 2 for "-B"
	      | otherwise	   
	      = do { maybe_exec_dir <- getBaseDir -- Get directory of executable
		   ; case maybe_exec_dir of	  -- (only works on Windows; 
						  --  returns Nothing on Unix)
			Nothing  -> throwDyn (InstallationError "missing -B<dir> option")
			Just dir -> return dir
		   }
\end{code}


%************************************************************************
%*									*
\subsection{Running an external program}
%*									*
%************************************************************************


\begin{code}
runUnlit :: DynFlags -> [Option] -> IO ()
runUnlit dflags args = do 
  let p = pgm_L dflags
  runSomething dflags "Literate pre-processor" p args

runCpp :: DynFlags -> [Option] -> IO ()
runCpp dflags args =   do 
  let (p,args0) = pgm_P dflags
  runSomething dflags "C pre-processor" p (args0 ++ args)

runPp :: DynFlags -> [Option] -> IO ()
runPp dflags args =   do 
  let p = pgm_F dflags
  runSomething dflags "Haskell pre-processor" p args

runCc :: DynFlags -> [Option] -> IO ()
runCc dflags args =   do 
  let (p,args0) = pgm_c dflags
  runSomething dflags "C Compiler" p (args0++args)

runMangle :: DynFlags -> [Option] -> IO ()
runMangle dflags args = do 
  let (p,args0) = pgm_m dflags
  runSomething dflags "Mangler" p (args0++args)

runSplit :: DynFlags -> [Option] -> IO ()
runSplit dflags args = do 
  let (p,args0) = pgm_s dflags
  runSomething dflags "Splitter" p (args0++args)

runAs :: DynFlags -> [Option] -> IO ()
runAs dflags args = do 
  let (p,args0) = pgm_a dflags
  runSomething dflags "Assembler" p (args0++args)

runLink :: DynFlags -> [Option] -> IO ()
runLink dflags args = do 
  let (p,args0) = pgm_l dflags
  runSomething dflags "Linker" p (args0++args)

runMkDLL :: DynFlags -> [Option] -> IO ()
runMkDLL dflags args = do
  let (p,args0) = pgm_dll dflags
  runSomething dflags "Make DLL" p (args0++args)

touch :: DynFlags -> String -> String -> IO ()
touch dflags purpose arg =  do 
  p <- readIORef v_Pgm_T
  runSomething dflags purpose p [FileOption "" arg]

copy :: DynFlags -> String -> String -> String -> IO ()
copy dflags purpose from to = do
  showPass dflags purpose

  h <- openFile to WriteMode
  ls <- readFile from -- inefficient, but it'll do for now.
	    	      -- ToDo: speed up via slurping.
  hPutStr h ls
  hClose h

\end{code}

\begin{code}
getSysMan :: IO String	-- How to invoke the system manager 
			-- (parallel system only)
getSysMan = readIORef v_Pgm_sysman
\end{code}

\begin{code}
getUsageMsgPaths :: IO (FilePath,FilePath)
	  -- the filenames of the usage messages (ghc, ghci)
getUsageMsgPaths = readIORef v_Path_usages
\end{code}


%************************************************************************
%*									*
\subsection{Managing temporary files
%*									*
%************************************************************************

\begin{code}
GLOBAL_VAR(v_FilesToClean, [],               [String] )
\end{code}

\begin{code}
cleanTempFiles :: DynFlags -> IO ()
cleanTempFiles dflags
   = do fs <- readIORef v_FilesToClean
	removeTmpFiles dflags fs
	writeIORef v_FilesToClean []

cleanTempFilesExcept :: DynFlags -> [FilePath] -> IO ()
cleanTempFilesExcept dflags dont_delete
   = do files <- readIORef v_FilesToClean
	let (to_keep, to_delete) = partition (`elem` dont_delete) files
	removeTmpFiles dflags to_delete
	writeIORef v_FilesToClean to_keep


-- find a temporary name that doesn't already exist.
newTempName :: DynFlags -> Suffix -> IO FilePath
newTempName DynFlags{tmpDir=tmp_dir} extn
  = do x <- getProcessID
       findTempName (tmp_dir ++ "/ghc" ++ show x ++ "_") 0
  where 
    findTempName prefix x
      = do let filename = (prefix ++ show x) `joinFileExt` extn
  	   b  <- doesFileExist filename
	   if b then findTempName prefix (x+1)
		else do consIORef v_FilesToClean filename -- clean it up later
		        return filename

addFilesToClean :: [FilePath] -> IO ()
-- May include wildcards [used by DriverPipeline.run_phase SplitMangle]
addFilesToClean files = mapM_ (consIORef v_FilesToClean) files

removeTmpFiles :: DynFlags -> [FilePath] -> IO ()
removeTmpFiles dflags fs
  = warnNon $
    traceCmd dflags "Deleting temp files" 
	     ("Deleting: " ++ unwords deletees)
	     (mapM_ rm deletees)
  where
     -- Flat out refuse to delete files that are likely to be source input
     -- files (is there a worse bug than having a compiler delete your source
     -- files?)
     -- 
     -- Deleting source files is a sign of a bug elsewhere, so prominently flag
     -- the condition.
    warnNon act
     | null non_deletees = act
     | otherwise         = do
        putMsg dflags (text "WARNING - NOT deleting source files:" <+> hsep (map text non_deletees))
	act

    (non_deletees, deletees) = partition isHaskellUserSrcFilename fs

    rm f = removeFile f `IO.catch` 
		(\_ignored -> 
		    debugTraceMsg dflags 2 (ptext SLIT("Warning: deleting non-existent") <+> text f)
		)


-----------------------------------------------------------------------------
-- Running an external program

runSomething :: DynFlags
	     -> String		-- For -v message
	     -> String		-- Command name (possibly a full path)
				-- 	assumed already dos-ified
	     -> [Option]	-- Arguments
				--	runSomething will dos-ify them
	     -> IO ()

runSomething dflags phase_name pgm args = do
  let real_args = filter notNull (map showOpt args)
  traceCmd dflags phase_name (unwords (pgm:real_args)) $ do
  (exit_code, doesn'tExist) <- 
     IO.catch (do
         rc <- builderMainLoop dflags pgm real_args
	 case rc of
	   ExitSuccess{} -> return (rc, False)
	   ExitFailure n 
             -- rawSystem returns (ExitFailure 127) if the exec failed for any
             -- reason (eg. the program doesn't exist).  This is the only clue
             -- we have, but we need to report something to the user because in
             -- the case of a missing program there will otherwise be no output
             -- at all.
	    | n == 127  -> return (rc, True)
	    | otherwise -> return (rc, False))
		-- Should 'rawSystem' generate an IO exception indicating that
		-- 'pgm' couldn't be run rather than a funky return code, catch
		-- this here (the win32 version does this, but it doesn't hurt
		-- to test for this in general.)
              (\ err -> 
	        if IO.isDoesNotExistError err 
#if defined(mingw32_HOST_OS) && __GLASGOW_HASKELL__ < 604
		-- the 'compat' version of rawSystem under mingw32 always
		-- maps 'errno' to EINVAL to failure.
		   || case (ioeGetErrorType err ) of { InvalidArgument{} -> True ; _ -> False}
#endif
	         then return (ExitFailure 1, True)
	         else IO.ioError err)
  case (doesn'tExist, exit_code) of
     (True, _)        -> throwDyn (InstallationError ("could not execute: " ++ pgm))
     (_, ExitSuccess) -> return ()
     _                -> throwDyn (PhaseFailed phase_name exit_code)



#if __GLASGOW_HASKELL__ < 603
builderMainLoop dflags pgm real_args = do
  rawSystem pgm real_args
#else
builderMainLoop dflags pgm real_args = do
  chan <- newChan
  (hStdIn, hStdOut, hStdErr, hProcess) <- runInteractiveProcess pgm real_args Nothing Nothing

  -- and run a loop piping the output from the compiler to the log_action in DynFlags
  hSetBuffering hStdOut LineBuffering
  hSetBuffering hStdErr LineBuffering
  forkIO (readerProc chan hStdOut)
  forkIO (readerProc chan hStdErr)
  rc <- loop chan hProcess 2 1 ExitSuccess
  hClose hStdIn
  hClose hStdOut
  hClose hStdErr
  return rc
  where
    -- status starts at zero, and increments each time either
    -- a reader process gets EOF, or the build proc exits.  We wait
    -- for all of these to happen (status==3).
    -- ToDo: we should really have a contingency plan in case any of
    -- the threads dies, such as a timeout.
    loop chan hProcess 0 0 exitcode = return exitcode
    loop chan hProcess t p exitcode = do
      mb_code <- if p > 0
                   then getProcessExitCode hProcess
                   else return Nothing
      case mb_code of
        Just code -> loop chan hProcess t (p-1) code
	Nothing 
	  | t > 0 -> do 
	      msg <- readChan chan
              case msg of
                BuildMsg msg -> do
                  log_action dflags SevInfo noSrcSpan defaultUserStyle msg
                  loop chan hProcess t p exitcode
                BuildError loc msg -> do
                  log_action dflags SevError (mkSrcSpan loc loc) defaultUserStyle msg
                  loop chan hProcess t p exitcode
                EOF ->
                  loop chan hProcess (t-1) p exitcode
          | otherwise -> loop chan hProcess t p exitcode

readerProc chan hdl = loop Nothing `catch` \e -> writeChan chan EOF
	-- ToDo: check errors more carefully
    where
         loop in_err = do
	        l <- hGetLine hdl `catch` \e -> do
			case in_err of
			  Just err -> writeChan chan err
			  Nothing  -> return ()
			ioError e
		case in_err of
		  Just err@(BuildError srcLoc msg)
		    | leading_whitespace l -> do
			loop (Just (BuildError srcLoc (msg $$ text l)))
		    | otherwise -> do
			writeChan chan err
			checkError l
		  Nothing -> do
			checkError l

	 checkError l
	   = case matchRegex errRegex l of
		Nothing -> do
		    writeChan chan (BuildMsg (text l))
		    loop Nothing
		Just (file':lineno':colno':msg:_) -> do
		    let file   = mkFastString file'
		        lineno = read lineno'::Int
		        colno  = case colno' of
		                   "" -> 0
		                   _  -> read (init colno') :: Int
		        srcLoc = mkSrcLoc file lineno colno
		    loop (Just (BuildError srcLoc (text msg)))

	 leading_whitespace []    = False
	 leading_whitespace (x:_) = isSpace x

errRegex = mkRegex "^([^:]*):([0-9]+):([0-9]+:)?(.*)"

data BuildMessage
  = BuildMsg   !SDoc
  | BuildError !SrcLoc !SDoc
  | EOF
#endif

showOpt (FileOption pre f) = pre ++ platformPath f
showOpt (Option "") = ""
showOpt (Option s)  = s

traceCmd :: DynFlags -> String -> String -> IO () -> IO ()
-- a) trace the command (at two levels of verbosity)
-- b) don't do it at all if dry-run is set
traceCmd dflags phase_name cmd_line action
 = do	{ let verb = verbosity dflags
	; showPass dflags phase_name
	; debugTraceMsg dflags 3 (text cmd_line)
	; hFlush stderr
	
	   -- Test for -n flag
	; unless (dopt Opt_DryRun dflags) $ do {

	   -- And run it!
	; action `IO.catch` handle_exn verb
	}}
  where
    handle_exn verb exn = do { debugTraceMsg dflags 2 (char '\n')
			     ; debugTraceMsg dflags 2 (ptext SLIT("Failed:") <+> text cmd_line <+> text (show exn))
	          	     ; throwDyn (PhaseFailed phase_name (ExitFailure 1)) }
\end{code}

%************************************************************************
%*									*
\subsection{Support code}
%*									*
%************************************************************************

\begin{code}
-----------------------------------------------------------------------------
-- Define	getBaseDir     :: IO (Maybe String)

getBaseDir :: IO (Maybe String)
#if defined(mingw32_HOST_OS)
-- Assuming we are running ghc, accessed by path  $()/bin/ghc.exe,
-- return the path $(stuff).  Note that we drop the "bin/" directory too.
getBaseDir = do let len = (2048::Int) -- plenty, PATH_MAX is 512 under Win32.
		buf <- mallocArray len
		ret <- getModuleFileName nullPtr buf len
		if ret == 0 then free buf >> return Nothing
		            else do s <- peekCString buf
				    free buf
				    return (Just (rootDir s))
  where
    rootDir s = reverse (dropList "/bin/ghc.exe" (reverse (normalisePath s)))

foreign import stdcall unsafe "GetModuleFileNameA"
  getModuleFileName :: Ptr () -> CString -> Int -> IO Int32
#else
getBaseDir = return Nothing
#endif

#ifdef mingw32_HOST_OS
foreign import ccall unsafe "_getpid" getProcessID :: IO Int -- relies on Int == Int32 on Windows
#elif __GLASGOW_HASKELL__ > 504
getProcessID :: IO Int
getProcessID = System.Posix.Internals.c_getpid >>= return . fromIntegral
#else
getProcessID :: IO Int
getProcessID = Posix.getProcessID
#endif

\end{code}
