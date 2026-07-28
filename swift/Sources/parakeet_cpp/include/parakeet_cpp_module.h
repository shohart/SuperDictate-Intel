// Umbrella header for the parakeet_cpp SwiftPM target.
//
// This deliberately exports ONLY SuperDictate's own C bridge
// (superdictate_parakeet.h), never upstream's parakeet_capi.h/parakeet.h
// directly — Swift never sees `parakeet_ctx`, `pk::Model`, or any other
// upstream C++ type. See docs/parakeet-intel-backend.md §7 ("Do not expose
// upstream C++ types directly to Swift").
#ifndef PARAKEET_CPP_MODULE_H
#define PARAKEET_CPP_MODULE_H

#include "superdictate_parakeet.h"

#endif
