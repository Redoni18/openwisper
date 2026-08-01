// SwiftPM requires at least one compilable source in a C target; CWhisper is
// otherwise header-only (the whisper.cpp object code is linked in from
// Vendor/whisper-install/lib by WhisperLocal). Pulling in the umbrella header
// here also turns a bad header copy into a compile error rather than a
// mysterious link failure later.
#include "include/CWhisper.h"
