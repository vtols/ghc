/* -----------------------------------------------------------------------------
 *
 * (c) The GHC Team 1998-2008
 *
 * Weak pointers and weak-like things in the GC
 *
 * Documentation on the architecture of the Garbage Collector can be
 * found in the online commentary:
 * 
 *   http://hackage.haskell.org/trac/ghc/wiki/Commentary/Rts/Storage/GC
 *
 * ---------------------------------------------------------------------------*/

#ifndef SM_MARKWEAK_H
#define SM_MARKWEAK_H

#include "BeginPrivate.h"

void    initWeakForGC          ( void );
rtsBool traverseWeakPtrList    ( void );
void    markWeakPtrList        ( void );

#include "EndPrivate.h"

#endif /* SM_MARKWEAK_H */
