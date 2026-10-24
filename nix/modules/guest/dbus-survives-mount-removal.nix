# See ./dbus-survives-mount-removal.md#context-1.
{
  config,
  lib,
  ...
}:
# See ./dbus-survives-mount-removal.md#context-2.
lib.mkIf (config.services.dbus.enable && config.services.dbus.implementation == "broker") {
  systemd.services.dbus-broker.unitConfig = {
    RequiresMountsFor = lib.mkForce [];
    WantsMountsFor = ["/tmp"];
  };
}
