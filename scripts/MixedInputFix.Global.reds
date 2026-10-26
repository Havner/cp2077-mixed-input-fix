// MixedInputFix script API - lets optional redscript mods switch the plugin's
// mode at runtime, e.g. inhibit it in photo mode, or pin the controller only
// while driving. Ships with the plugin (red4ext/plugins/MixedInputFix/scripts)
// and is added to the redscript compilation by the DLL itself.
//
//   MixedInputFix.SetMode(MixedInputFixMode.KBM);
//   let saved = MixedInputFix.GetMode();
//   MixedInputFix.ResetMode(); // back to the mode in MixedInputFix.ini
//
// Semantics:
//   * A new mode takes hold on the next real input of its target device
//     (pad for Controller, keyboard/mouse for KBM). Until then the game runs
//     vanilla, so every switch is a normal device transition.
//   * Inhibited pins nothing: vanilla behaviour, including the device flip
//     churn the fix exists to remove. Fine for occasional use (photo mode);
//     prefer KBM for long stretches.
//   * The runtime mode is never saved. It resets to the ini mode whenever the
//     player detaches (loading a save, quitting to the main menu), so mods
//     should re-apply theirs when their situation starts again.
//   * Last call wins - there is no stacking between mods. Use GetMode() to
//     save and restore around a temporary change.
//   * With enabled=0 in MixedInputFix.ini every call is refused (SetMode and
//     ResetMode return false, GetMode returns Disabled).
//
// Optional dependency: wrap calls in @if(ModuleExists("MixedInputFix")) to
// compile without the plugin installed.

public enum MixedInputFixMode {
  Inhibited = 0,
  Controller = 1,
  KBM = 2,
  Disabled = 3, // GetMode() only
}

public abstract class MixedInputFix {
  public static func SetMode(mode: MixedInputFixMode) -> Bool {
    return MixedInputFix_SetMode(EnumInt(mode));
  }

  public static func GetMode() -> MixedInputFixMode {
    return IntEnum<MixedInputFixMode>(MixedInputFix_GetMode());
  }

  public static func ResetMode() -> Bool {
    return MixedInputFix_ResetMode();
  }
}

// Raw natives (registered by MixedInputFix.dll) - use the class above.
public static native func MixedInputFix_SetMode(mode: Int32) -> Bool
public static native func MixedInputFix_GetMode() -> Int32
public static native func MixedInputFix_ResetMode() -> Bool

// Session boundary: restore the ini mode so a mode set by a script mod never
// leaks into the next session (e.g. loading an on-foot save from a vehicle).
@wrapMethod(PlayerPuppet)
protected cb func OnDetach() -> Bool {
  MixedInputFix_ResetMode();
  return wrappedMethod();
}
