# See ./tmp-stays-writable.md#context-1.
_: {
  system.activationScripts.tmpWritable = ''
    mode=$(stat -c %a /tmp)
    if [ "$mode" != "1777" ]; then
      echo "platform: /tmp is $mode, restoring 1777"
      chmod 1777 /tmp
    fi
  '';
}
