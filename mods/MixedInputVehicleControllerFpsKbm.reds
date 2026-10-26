// MixedInputVehicleControllerFpsKbm 1.0 - optional companion mod for
// MixedInputFix.
//
// For players who drive with a gamepad and fight with keyboard/mouse: pins
// the UI to the controller when V gets into a vehicle and to keyboard/mouse
// when V gets out. A minimal example of the MixedInputFix script API.
//
// Install: r6/scripts/MixedInputVehicleControllerFpsKbm/MixedInputVehicleControllerFpsKbm.reds
// Requires: redscript, MixedInputFix 1.1.0+ (script API).

// Vanilla sets m_mountedVehicle here only when the mount is a vehicle.
@wrapMethod(PlayerPuppet)
protected cb func OnMountingEvent(evt: ref<MountingEvent>) -> Bool {
  let result = wrappedMethod(evt);
  if IsDefined(this.m_mountedVehicle) {
    MixedInputFix.SetMode(MixedInputFixMode.Controller);
  }
  return result;
}

// ...and clears it only when it is the player leaving the vehicle.
@wrapMethod(PlayerPuppet)
protected cb func OnUnmountingEvent(evt: ref<UnmountingEvent>) -> Bool {
  let wasInVehicle = IsDefined(this.m_mountedVehicle);
  let result = wrappedMethod(evt);
  if wasInVehicle && !IsDefined(this.m_mountedVehicle) {
    MixedInputFix.SetMode(MixedInputFixMode.KBM);
  }
  return result;
}
