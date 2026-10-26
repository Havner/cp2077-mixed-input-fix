// MixedInputInhibitOnPhotoMode 1.0 - optional companion mod for MixedInputFix.
//
// Inhibits MixedInputFix while photo mode is open, so photo mode behaves as
// in vanilla (mouse cursor, keyboard/mouse controls), and puts the previous
// mode back on exit. A minimal example of the MixedInputFix script API.
//
// Install: r6/scripts/MixedInputInhibitOnPhotoMode/MixedInputInhibitOnPhotoMode.reds
// Requires: redscript, MixedInputFix 1.1.0+ (script API).

@addField(gameuiPhotoModeMenuController)
private let m_mixedInputSavedMode: MixedInputFixMode;

@wrapMethod(gameuiPhotoModeMenuController)
protected cb func OnShow(reversedUI: Bool) -> Bool {
  this.m_mixedInputSavedMode = MixedInputFix.GetMode();
  MixedInputFix.SetMode(MixedInputFixMode.Inhibited);
  return wrappedMethod(reversedUI);
}

@wrapMethod(gameuiPhotoModeMenuController)
protected cb func OnHide() -> Bool {
  MixedInputFix.SetMode(this.m_mixedInputSavedMode);
  return wrappedMethod();
}
