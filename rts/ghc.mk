# -----------------------------------------------------------------------------
#
# (c) 2009 The University of Glasgow
#
# This file is part of the GHC build system.
#
# To understand how the build system works and how to modify it, see
#      http://hackage.haskell.org/trac/ghc/wiki/Building/Architecture
#      http://hackage.haskell.org/trac/ghc/wiki/Building/Modifying
#
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Building the RTS

# We build the RTS with stage 1
rts_dist_HC = $(GHC_STAGE1)

# merge GhcLibWays and GhcRTSWays but strip out duplicates
rts_WAYS = $(GhcLibWays) $(filter-out $(GhcLibWays),$(GhcRTSWays))
rts_dist_WAYS = $(rts_WAYS)

ALL_RTS_LIBS = rts/dist/build/libHSrtsmain.a \
	       $(foreach way,$(rts_WAYS),rts/dist/build/libHSrts$($(way)_libsuf))
all_rts : $(ALL_RTS_LIBS)

# -----------------------------------------------------------------------------
# Defining the sources

ALL_DIRS = hooks parallel sm eventlog

ifeq "$(HOSTPLATFORM)" "i386-unknown-mingw32"
ALL_DIRS += win32
else
ALL_DIRS += posix
endif

EXCLUDED_SRCS += rts/Main.c
EXCLUDED_SRCS += rts/parallel/SysMan.c
EXCLUDED_SRCS += rts/dyn-wrapper.c
EXCLUDED_SRCS += $(wildcard rts/Vis*.c)

rts_C_SRCS = $(filter-out $(EXCLUDED_SRCS),$(wildcard rts/*.c $(foreach dir,$(ALL_DIRS),rts/$(dir)/*.c)))
rts_CMM_SRCS = $(wildcard rts/*.cmm)

# Don't compile .S files when bootstrapping a new arch
ifeq "$(TARGETPLATFORM)" "$(HOSTPLATFORM)"
ifneq "$(findstring $(TargetArch_CPP), powerpc powerpc64)" ""
rts_S_SRCS += rts/AdjustorAsm.S
else
ifneq "$(findstring $(TargetOS_CPP), darwin)" ""
rts_S_SRCS += rts/AdjustorAsm.S
endif
endif
endif

ifeq "$(GhcUnregisterised)" "YES"
GENAPPLY_OPTS = -u
endif

rts_AUTO_APPLY_CMM = rts/dist/build/AutoApply.cmm

$(rts_AUTO_APPLY_CMM): $(GENAPPLY_INPLACE)
	"$(GENAPPLY_INPLACE)" >$@

rts/dist/build/sm/Evac_thr.c : rts/sm/Evac.c | $$(dir $$@)/.
	cp $< $@
rts/dist/build/sm/Scav_thr.c : rts/sm/Scav.c | $$(dir $$@)/.
	cp $< $@

rts_H_FILES = $(wildcard includes/*.h) $(wildcard rts/*.h)

ifeq "$(HaveDtrace)" "YES"
DTRACEPROBES_H = rts/dist/build/RtsProbes.h
rts_H_FILES += $(DTRACEPROBES_H)
endif

# collect the -l flags that we need to link the rts dyn lib.
rts/libs.depend : $(GHC_PKG_INPLACE)
	"$(GHC_PKG_INPLACE)" field rts extra-libraries \
	  | sed -e 's/^extra-libraries: //' -e 's/\([a-z0-9]*\)[ ]*/-l\1 /g' > $@


# ----------------------------------------------------------------------------
# On Windows, as the RTS and base libraries have recursive imports,
# 	we have to break the loop with "import libraries".
# 	These are made from rts/win32/libHS*.def which contain lists of
# 	all the symbols in those libraries used by the RTS.
#
ifneq "$$(findstring dyn, $1)" ""
ifeq  "$(HOSTPLATFORM)" "i386-unknown-mingw32" 

ALL_RTS_DEF_LIBNAMES 	= base ghc-prim
ALL_RTS_DEF_LIBS	= \
	rts/dist/build/win32/libHSbase.dll.a \
	rts/dist/build/win32/libHSghc-prim.dll.a \
	rts/dist/build/win32/libHSffi.dll.a 

# -- import libs for the regular Haskell libraries
define make-importlib-def # args $1 = lib name
rts/dist/build/win32/libHS$1.def : rts/win32/libHS$1.def
	cat rts/win32/libHS$1.def \
		| sed "s/@LibVersion@/$$(libraries/$1_dist-install_VERSION)/" \
		| sed "s/@ProjectVersion@/$(ProjectVersion)/" \
		> rts/dist/build/win32/libHS$1.def

rts/dist/build/win32/libHS$1.dll.a : rts/dist/build/win32/libHS$1.def
	"$$(DLLTOOL)" 	-d rts/dist/build/win32/libHS$1.def \
			-l rts/dist/build/win32/libHS$1.dll.a
endef
$(foreach lib,$(ALL_RTS_DEF_LIBNAMES),$(eval $(call make-importlib-def,$(lib))))


# -- import libs for libffi
rts/dist/build/win32/libHSffi.def : rts/win32/libHSffi.def
	cat rts/win32/libHSffi.def \
		| sed "s/@ProjectVersion@/$(ProjectVersion)/" \
		> rts/dist/build/win32/libHSffi.def

rts/dist/build/win32/libHSffi.dll.a : rts/dist/build/win32/libHSffi.def
	"$(DLLTOOL)" 	-d rts/dist/build/win32/libHSffi.def \
			-l rts/dist/build/win32/libHSffi.dll.a
endif
endif


#-----------------------------------------------------------------------------
# Building one way
define build-rts-way # args: $1 = way

ifneq "$$(BINDIST)" "YES"

# The per-way CC_OPTS
ifneq "$$(findstring debug, $1)" ""
rts_dist_$1_HC_OPTS =
rts_dist_$1_CC_OPTS = -g -O0
else
rts_dist_$1_HC_OPTS = $$(GhcRtsHcOpts)
rts_dist_$1_CC_OPTS = $$(GhcRtsCcOpts)
endif

ifneq "$$(findstring thr, $1)" ""
rts_$1_EXTRA_C_SRCS  =  rts/dist/build/sm/Evac_thr.c rts/dist/build/sm/Scav_thr.c
endif

$(call distdir-way-opts,rts,dist,$1)
$(call c-suffix-rules,rts,dist,$1,YES)
$(call cmm-suffix-rules,rts,dist,$1)
$(call hs-suffix-rules-srcdir,rts,dist,$1,$$(dir))
# hs-suffix-rules-srcdir is needed when BootingFromHc to get the .hc rules

rts_$1_LIB_NAME = libHSrts$$($1_libsuf)
rts_$1_LIB = rts/dist/build/$$(rts_$1_LIB_NAME)

rts_$1_C_OBJS   = $$(patsubst rts/%.c,rts/dist/build/%.$$($1_osuf),$$(rts_C_SRCS)) $$(patsubst %.c,%.$$($1_osuf),$$(rts_$1_EXTRA_C_SRCS))
rts_$1_S_OBJS   = $$(patsubst rts/%.S,rts/dist/build/%.$$($1_osuf),$$(rts_S_SRCS))
rts_$1_CMM_OBJS = $$(patsubst rts/%.cmm,rts/dist/build/%.$$($1_osuf),$$(rts_CMM_SRCS)) $$(patsubst %.cmm,%.$$($1_osuf),$$(rts_AUTO_APPLY_CMM))

rts_$1_OBJS = $$(rts_$1_C_OBJS) $$(rts_$1_S_OBJS) $$(rts_$1_CMM_OBJS)

rts_dist_$1_CC_OPTS += -DRtsWay=$$(DQ)rts_$1$$(DQ)

# Making a shared library for the RTS.
ifneq "$$(findstring dyn, $1)" ""
ifeq "$$(HOSTPLATFORM)" "i386-unknown-mingw32"
$$(rts_$1_LIB) : $$(rts_$1_OBJS) $$(ALL_RTS_DEF_LIBS) rts/libs.depend
	"$$(RM)" $$(RM_OPTS) $$@
	"$$(rts_dist_HC)" -shared -dynamic -dynload deploy \
	  -no-auto-link-packages `cat rts/libs.depend` $$(rts_$1_OBJS) $$(ALL_RTS_DEF_LIBS) -o $$@
ifeq "$$(darwin_TARGET_OS)" "1"
	# Ensure library's install name is correct before anyone links with it.
	install_name_tool -id $(ghclibdir)/$$(rts_$1_LIB_NAME) $$@
endif
else
$$(rts_$1_LIB) : $$(rts_$1_OBJS) rts/libs.depend
	"$$(RM)" $$(RM_OPTS) $$@
	"$$(rts_dist_HC)" -shared -dynamic -dynload deploy \
	  -no-auto-link-packages `cat rts/libs.depend` $$(rts_$1_OBJS) -o $$@
endif
else
$$(rts_$1_LIB) : $$(rts_$1_OBJS)
	"$$(RM)" $$(RM_OPTS) $$@
	echo $$(rts_$1_OBJS) | "$$(XARGS)" $$(XARGS_OPTS) "$$(AR)" $$(AR_OPTS) $$(EXTRA_AR_ARGS) $$@
endif

endif

endef

# And expand the above for each way:
$(foreach way,$(rts_WAYS),$(eval $(call build-rts-way,$(way))))

#-----------------------------------------------------------------------------
# Flags for compiling every file

# We like plenty of warnings.
WARNING_OPTS += -Wall
ifeq "$(GccLT34)" "YES"
WARNING_OPTS += -W
else
WARNING_OPTS += -Wextra
endif
WARNING_OPTS += -Wstrict-prototypes 
WARNING_OPTS += -Wmissing-prototypes 
WARNING_OPTS += -Wmissing-declarations
WARNING_OPTS += -Winline
WARNING_OPTS += -Waggregate-return
WARNING_OPTS += -Wpointer-arith
WARNING_OPTS += -Wmissing-noreturn
WARNING_OPTS += -Wnested-externs
WARNING_OPTS += -Wredundant-decls 

# These ones are hard to avoid:
#WARNING_OPTS += -Wconversion
#WARNING_OPTS += -Wbad-function-cast
#WARNING_OPTS += -Wshadow
#WARNING_OPTS += -Wcast-qual

# This one seems buggy on GCC 4.1.2, which is the only GCC version we 
# have that can bootstrap the SPARC build. We end up with lots of supurious
# warnings of the form "cast increases required alignment of target type".
# Some legitimate warnings can be fixed by adding an intermediate cast to
# (void*), but we get others in rts/sm/GCUtils.c concerning the gct var
# that look innocuous to me. We could enable this again once we deprecate
# support for registerised builds on this arch. -- BL 2010/02/03
# WARNING_OPTS += -Wcast-align

STANDARD_OPTS += -Iincludes -Irts
# COMPILING_RTS is only used when building Win32 DLL support.
STANDARD_OPTS += -DCOMPILING_RTS

# HC_OPTS is included in both .c and .cmm compilations, whereas CC_OPTS is
# only included in .c compilations.  HC_OPTS included the WAY_* opts, which
# must be included in both types of compilations.

rts_CC_OPTS += $(WARNING_OPTS)
rts_CC_OPTS += $(STANDARD_OPTS)

rts_HC_OPTS += $(STANDARD_OPTS) -package-name rts

ifneq "$(GhcWithSMP)" "YES"
rts_CC_OPTS += -DNOSMP
rts_HC_OPTS += -optc-DNOSMP
endif

ifeq "$(UseLibFFIForAdjustors)" "YES"
rts_CC_OPTS += -DUSE_LIBFFI_FOR_ADJUSTORS
endif

# Mac OS X: make sure we compile for the right OS version
rts_CC_OPTS += $(MACOSX_DEPLOYMENT_CC_OPTS)
rts_HC_OPTS += $(addprefix -optc, $(MACOSX_DEPLOYMENT_CC_OPTS))
rts_LD_OPTS += $(addprefix -optl, $(MACOSX_DEPLOYMENT_LD_OPTS))

# Otherwise the stack-smash handler gets triggered.
ifneq "$(findstring $(TargetOS_CPP), darwin openbsd)" ""
rts_HC_OPTS += -optc-fno-stack-protector
endif

# We *want* type-checking of hand-written cmm.
rts_HC_OPTS += -dcmm-lint 

# -fno-strict-aliasing is required for the runtime, because we often
# use a variety of types to represent closure pointers (StgPtr,
# StgClosure, StgMVar, etc.), and without -fno-strict-aliasing gcc is
# allowed to assume that these pointers do not alias.  eg. without
# this flag we get problems in sm/Evac.c:copy() with gcc 3.4.3, the
# upd_evacee() assigments get moved before the object copy.
rts_CC_OPTS += -fno-strict-aliasing

rts_CC_OPTS += -fno-common

ifeq "$(BeConservative)" "YES"
rts_CC_OPTS += -DBE_CONSERVATIVE
endif

#-----------------------------------------------------------------------------
# Flags for compiling specific files

# XXX DQ is now the same on all platforms, so get rid of it
DQ = \"

# If RtsMain.c is built with optimisation then the SEH exception stuff on
# Windows gets confused.
# This has to be in HC rather than CC opts, as otherwise there's a
# -optc-O2 that comes after it.
rts/RtsMain_HC_OPTS += -optc-O0

rts/RtsMessages_CC_OPTS += -DProjectVersion=$(DQ)$(ProjectVersion)$(DQ)
rts/RtsUtils_CC_OPTS += -DProjectVersion=$(DQ)$(ProjectVersion)$(DQ)
#
rts/RtsUtils_CC_OPTS += -DHostPlatform=$(DQ)$(HOSTPLATFORM)$(DQ)
rts/RtsUtils_CC_OPTS += -DHostArch=$(DQ)$(HostArch_CPP)$(DQ)
rts/RtsUtils_CC_OPTS += -DHostOS=$(DQ)$(HostOS_CPP)$(DQ)
rts/RtsUtils_CC_OPTS += -DHostVendor=$(DQ)$(HostVendor_CPP)$(DQ)
#
rts/RtsUtils_CC_OPTS += -DBuildPlatform=$(DQ)$(BUILDPLATFORM)$(DQ)
rts/RtsUtils_CC_OPTS += -DBuildArch=$(DQ)$(BuildArch_CPP)$(DQ)
rts/RtsUtils_CC_OPTS += -DBuildOS=$(DQ)$(BuildOS_CPP)$(DQ)
rts/RtsUtils_CC_OPTS += -DBuildVendor=$(DQ)$(BuildVendor_CPP)$(DQ)
#
rts/RtsUtils_CC_OPTS += -DTargetPlatform=$(DQ)$(TARGETPLATFORM)$(DQ)
rts/RtsUtils_CC_OPTS += -DTargetArch=$(DQ)$(TargetArch_CPP)$(DQ)
rts/RtsUtils_CC_OPTS += -DTargetOS=$(DQ)$(TargetOS_CPP)$(DQ)
rts/RtsUtils_CC_OPTS += -DTargetVendor=$(DQ)$(TargetVendor_CPP)$(DQ)
#
rts/RtsUtils_CC_OPTS += -DGhcUnregisterised=$(DQ)$(GhcUnregisterised)$(DQ)
rts/RtsUtils_CC_OPTS += -DGhcEnableTablesNextToCode=$(DQ)$(GhcEnableTablesNextToCode)$(DQ)

# ffi.h triggers prototype warnings, so disable them here:
rts/Interpreter_CC_OPTS += -Wno-strict-prototypes
rts/Adjustor_CC_OPTS    += -Wno-strict-prototypes
rts/sm/Storage_CC_OPTS  += -Wno-strict-prototypes

# inlining warnings happen in Compact
rts/sm/Compact_CC_OPTS += -Wno-inline

# emits warnings about call-clobbered registers on x86_64
rts/StgCRun_CC_OPTS += -w

rts/RetainerProfile_CC_OPTS += -w
rts/RetainerSet_CC_OPTS += -Wno-format
# On Windows:
rts/win32/ConsoleHandler_CC_OPTS += -w
rts/win32/ThrIOManager_CC_OPTS += -w
# The above warning supression flags are a temporary kludge.
# While working on this module you are encouraged to remove it and fix
# any warnings in the module. See
#     http://hackage.haskell.org/trac/ghc/wiki/WorkingConventions#Warnings
# for details

# Without this, thread_obj will not be inlined (at least on x86 with GCC 4.1.0)
rts/sm/Compact_CC_OPTS += -finline-limit=2500

# -O3 helps unroll some loops (especially in copy() with a constant argument).
rts/sm/Evac_CC_OPTS += -funroll-loops
rts/dist/build/sm/Evac_thr_HC_OPTS += -optc-funroll-loops

# These files are just copies of sm/Evac.c and sm/Scav.c respectively,
# but compiled with -DPARALLEL_GC.
rts/dist/build/sm/Evac_thr_CC_OPTS += -DPARALLEL_GC -Irts/sm
rts/dist/build/sm/Scav_thr_CC_OPTS += -DPARALLEL_GC -Irts/sm

#-----------------------------------------------------------------------------
# Add PAPI library if needed

ifeq "$(GhcRtsWithPapi)" "YES"

rts_CC_OPTS		+= -DUSE_PAPI

rts_PACKAGE_CPP_OPTS	+= -DUSE_PAPI
rts_PACKAGE_CPP_OPTS    += -DPAPI_INCLUDE_DIR=$(PapiIncludeDir)
rts_PACKAGE_CPP_OPTS    += -DPAPI_LIB_DIR=$(PapiLibDir)

ifneq "$(PapiIncludeDir)" ""
rts_HC_OPTS     += -I$(PapiIncludeDir)
rts_CC_OPTS     += -I$(PapiIncludeDir)
rts_HSC2HS_OPTS += -I$(PapiIncludeDir)
endif
ifneq "$(PapiLibDirs)" ""
rts_LD_OPTS     += -L$(PapiLibDirs)
endif

else # GhcRtsWithPapi==YES

rts_PACKAGE_CPP_OPTS += -DPAPI_INCLUDE_DIR=""
rts_PACKAGE_CPP_OPTS += -DPAPI_LIB_DIR=""

endif

# -----------------------------------------------------------------------------
# dependencies

rts_WAYS_DASHED = $(subst $(space),,$(patsubst %,-%,$(strip $(rts_WAYS))))
rts_dist_depfile_base = rts/dist/build/.depend$(rts_WAYS_DASHED)

rts_dist_C_SRCS  = $(rts_C_SRCS) $(rts_thr_EXTRA_C_SRCS)
rts_dist_S_SRCS =  $(rts_S_SRCS)
rts_dist_C_FILES = $(rts_C_SRCS) $(rts_thr_EXTRA_C_SRCS) $(rts_S_SRCS)

# Hack: we define every way-related option here, so that we get (hopefully)
# a superset of the dependencies.  To do this properly, we should generate
# a different set of dependencies for each way.  Further hack: PROFILING an

# TICKY_TICKY can't be used together, so we omit TICKY_TICKY for now.
rts_dist_MKDEPENDC_OPTS += -DPROFILING -DTHREADED_RTS -DDEBUG

ifeq "$(HaveDtrace)" "YES"

rts_dist_MKDEPENDC_OPTS += -Irts/dist/build

endif

$(eval $(call build-dependencies,rts,dist))

$(rts_dist_depfile_c_asm) : libffi/dist-install/build/ffi.h $(DTRACEPROBES_H)

#-----------------------------------------------------------------------------
# libffi stuff

rts_CC_OPTS     += -Ilibffi/build/include
rts_HC_OPTS     += -Ilibffi/build/include
rts_HSC2HS_OPTS += -Ilibffi/build/include
rts_LD_OPTS     += -Llibffi/build/include

# -----------------------------------------------------------------------------
# compile generic patchable dyn-wrapper

DYNWRAPPER_SRC = rts/dyn-wrapper.c
DYNWRAPPER_PROG = rts/dyn-wrapper$(exeext)
$(DYNWRAPPER_PROG): $(DYNWRAPPER_SRC)
	"$(HC)" -cpp -optc-include -optcdyn-wrapper-patchable-behaviour.h $(INPLACE_EXTRA_FLAGS) $< -o $@

# -----------------------------------------------------------------------------
# compile dtrace probes if dtrace is supported

ifeq "$(HaveDtrace)" "YES"

rts_CC_OPTS		+= -DDTRACE
rts_HC_OPTS		+= -DDTRACE

DTRACEPROBES_SRC = rts/RtsProbes.d
$(DTRACEPROBES_H): $(DTRACEPROBES_SRC) | $(dir $@)/.
	"$(DTRACE)" $(filter -I%,$(rts_CC_OPTS)) -C -h -o $@ -s $<

endif

# -----------------------------------------------------------------------------
# build the static lib containing the C main symbol

ifneq "$(BINDIST)" "YES"
rts/dist/build/libHSrtsmain.a : rts/dist/build/Main.o
	"$(AR)" $(AR_OPTS) $(EXTRA_AR_ARGS) $@ $<
endif

# -----------------------------------------------------------------------------
# The RTS package config

# If -DDEBUG is in effect, adjust package conf accordingly..
ifneq "$(strip $(filter -optc-DDEBUG,$(GhcRtsHcOpts)))" ""
rts_PACKAGE_CPP_OPTS += -DDEBUG
endif

ifeq "$(HaveLibMingwEx)" "YES"
rts_PACKAGE_CPP_OPTS += -DHAVE_LIBMINGWEX
endif

$(eval $(call manual-package-config,rts))

ifneq "$(BootingFromHc)" "YES"
rts/package.conf.inplace : $(includes_H_CONFIG) $(includes_H_PLATFORM)
endif

# -----------------------------------------------------------------------------
# installing

INSTALL_LIBS += $(ALL_RTS_LIBS)

# -----------------------------------------------------------------------------
# cleaning

$(eval $(call clean-target,rts,dist,rts/dist))

BINDIST_EXTRAS += rts/package.conf.in
BINDIST_EXTRAS += $(ALL_RTS_LIBS)

