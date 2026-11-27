// Copyright 2026 The Haze Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef HAZE_COMPONENTS_DEFAULT_PREFS_DEFAULT_PREFS_H_
#define HAZE_COMPONENTS_DEFAULT_PREFS_DEFAULT_PREFS_H_

namespace user_prefs {
class PrefRegistrySyncable;
}  // namespace user_prefs

namespace haze {

// Replaces the defaults of profile prefs Chromium has already registered with
// the ones docs/SPEC.md section 3 asks for. Only the defaults change: a value
// the user set is stored as a user value and keeps taking precedence.
//
// Must run after every pref it touches is registered.
void SetProfilePrefDefaults(user_prefs::PrefRegistrySyncable* registry);

}  // namespace haze

#endif  // HAZE_COMPONENTS_DEFAULT_PREFS_DEFAULT_PREFS_H_
