// MixedInputBindings 1.0 - key bindings that pin MixedInputFix to a device.
//
// Two input actions: MixedInputPinController switches MixedInputFix to
// Controller, MixedInputPinKBM to KBM. By default they sit on pad A and Space,
// i.e. jump on foot and handbrake while driving, so changing control schemes
// mid-game is just pressing that button on the device you're picking up.
//
// The actions and their keys are defined in r6/input/MixedInputBindings.xml
// (merged by input_loader) - edit the <button> ids there to rebind. They need
// their own mappings: vanilla Jump_Button and Vehicle_Handbrake each hold both
// IK_Pad_A_CROSS and IK_Space (r6/config/inputUserMappings.xml:455, :1190),
// and a ListenerAction carries no device, so those actions can't tell which
// one was pressed. Jump/handbrake still fire as usual; these listen alongside.
// Contexts: Locomotion (next to Jump, inputContexts.xml:1041), the two
// driving bases next to Handbrake, VehicleDriveBase (:453) and
// BaseVehicleDriverCombat (:695), plus the other vehicle states: quickhack
// panel while driving, remote control, tank, passenger, autodrive, Delamain
// taxi, cinematic camera.
//
// The actions are registered on the player the way vanilla registers its own
// (PlayerPuppet.OnGameAttached, cyberpunk/player/player.swift:1147) and handled
// in PlayerPuppet.OnAction (player.swift:1297). SetMode to the current mode
// is a no-op in MixedInputFix (keeps it engaged), so repeated presses are free.
// The pin takes hold on the next input of the chosen device (MixedInputFix
// API semantics) and resets to the ini mode on save load / main menu.
//
// Install: r6/scripts/MixedInputBindings/MixedInputBindings.reds
//          r6/input/MixedInputBindings.xml
// Requires: redscript, input_loader, MixedInputFix 1.1.0+ (script API).

@wrapMethod(PlayerPuppet)
protected cb func OnGameAttached() -> Bool {
  let result = wrappedMethod();
  this.RegisterInputListener(this, n"MixedInputPinController");
  this.RegisterInputListener(this, n"MixedInputPinKBM");
  return result;
}

@wrapMethod(PlayerPuppet)
protected cb func OnAction(action: ListenerAction, consumer: ListenerActionConsumer) -> Bool {
  if ListenerAction.IsButtonJustPressed(action) {
    let name = ListenerAction.GetName(action);
    if Equals(name, n"MixedInputPinController") {
      MixedInputFix.SetMode(MixedInputFixMode.Controller);
    } else if Equals(name, n"MixedInputPinKBM") {
      MixedInputFix.SetMode(MixedInputFixMode.KBM);
    };
  };
  return wrappedMethod(action, consumer);
}
