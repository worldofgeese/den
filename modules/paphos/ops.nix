{den, ...}: let
  motherBackupBase = "/volume1/homes/taohansen/jd/70-79 Operations/71 Server backups/paphos/forgejo";
  # mother's LAN address. Since 2026-10-31, mother's authorized_keys accepts
  # the backup key only from paphos' own addresses (from=). Over MagicDNS,
  # mother refuses the key, and over the LAN it accepts it.
  motherLanAddress = "192.168.99.200";
  telegramChatId = "488228716";
  oracleTailscaleIp = "100.87.121.45";
  oracleHost = "oracle.hound-celsius.ts.net";
  lkLanAddress = "192.168.99.134";
  lkTailscaleIp = "100.80.28.13";
  haTailnetName = "home-assistant.hound-celsius.ts.net";
  hostKeys = import ../_host-keys.nix;
  # loving-kypris refreshes this file after each verified Mother recovery
  # checkpoint (scripts/fleet-maintenance/checkpoint-heartbeat.sh). The key
  # can only write the current time to this one file.
  heartbeatDir = "/var/lib/fleet-heartbeat";
  motherCheckpointKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPQtJL7eaPwnIbpe2Ur3/kEaKvP95f3r9p/1JJc9cyBI fleet-heartbeat@loving-kypris";
in {
  den.aspects.paphos.nixos = {
    config,
    lib,
    pkgs,
    ...
  }: let
    inherit (pkgs) coreutils curl gawk gzip gnutar iputils jq openssh postgresql rsync systemd util-linux;
    tailscaleBin = lib.getExe config.services.tailscale.package;
    healthScript = pkgs.writeShellScript "paphos-health-check" ''
      set -euo pipefail

      token_file="/run/agenix/telegram-lbob-bot-token"
      chat_id="${telegramChatId}"
      host="paphos"
      failures=""

      record_failure() {
        failures="$failures $1"
      }

      notify() {
        local text="$1"
        if [[ -f "$token_file" ]]; then
          ${curl}/bin/curl -fsS -X POST \
            "https://api.telegram.org/bot$(cat "$token_file")/sendMessage" \
            -d "chat_id=$chat_id" \
            --data-urlencode "text=$text" >/dev/null || true
        fi
      }

      if ! ${curl}/bin/curl -fsS --max-time 10 http://127.0.0.1:3000/ >/dev/null; then
        record_failure forgejo-http
      fi

      if ! ${systemd}/bin/systemctl is-active --quiet tailscaled.service; then
        record_failure tailscaled
      fi

      if ${systemd}/bin/systemctl is-failed --quiet nixos-upgrade.service; then
        record_failure nixos-upgrade-failed
      fi

      if ${systemd}/bin/systemctl is-failed --quiet paphos-firmware-update.service; then
        record_failure firmware-update-failed
      fi

      if ${systemd}/bin/systemctl list-unit-files forgesync-job-github.timer >/dev/null 2>&1; then
        if ! ${systemd}/bin/systemctl is-active --quiet forgesync-job-github.timer; then
          record_failure forgesync-timer
        fi
      fi

      root_use=$(${coreutils}/bin/df -P / | ${gawk}/bin/awk 'NR==2 {gsub(/%/,"",$5); print $5}')
      if [[ "$root_use" -ge 90 ]]; then
        record_failure "disk-root-''${root_use}pct"
      fi

      if [[ -f /var/lib/paphos/forgejo-backup-last-success ]]; then
        last_epoch=$(${coreutils}/bin/cat /var/lib/paphos/forgejo-backup-last-success)
        now_epoch=$(${coreutils}/bin/date +%s)
        age_hours=$(( (now_epoch - last_epoch) / 3600 ))
        if [[ "$age_hours" -gt 36 ]]; then
          record_failure "forgejo-backup-stale-''${age_hours}h"
        fi
      else
        record_failure forgejo-backup-never
      fi

      # Absent or old heartbeat: the daily checkpoint on loving-kypris failed,
      # did not run, or loving-kypris is down.
      beat_file="${heartbeatDir}/mother-checkpoint"
      if [[ -f "$beat_file" ]]; then
        beat_epoch=$(${coreutils}/bin/cat "$beat_file")
        [[ "$beat_epoch" =~ ^[0-9]+$ ]] || beat_epoch=0
        beat_age_hours=$(( ($(${coreutils}/bin/date +%s) - beat_epoch) / 3600 ))
        if [[ "$beat_age_hours" -gt 36 ]]; then
          record_failure "mother-checkpoint-stale-''${beat_age_hours}h"
        fi
      else
        record_failure mother-checkpoint-never
      fi

      # An installed kernel that is not booted means unattended reboots are not
      # happening: Tang was down at boot, or the reboot window keeps being
      # missed. paphos once ran 7.0.3 for 175 days that way.
      now_epoch=$(${coreutils}/bin/date +%s)
      booted_kernel=$(${coreutils}/bin/readlink -f /run/booted-system/kernel)
      current_kernel=$(${coreutils}/bin/readlink -f /run/current-system/kernel)
      if [[ "$booted_kernel" != "$current_kernel" ]]; then
        switched_epoch=$(${coreutils}/bin/stat -c %Y /run/current-system)
        pending_days=$(( (now_epoch - switched_epoch) / 86400 ))
        if [[ "$pending_days" -ge 2 ]]; then
          record_failure "reboot-pending-''${pending_days}d"
        fi
      fi

      # nixpkgs follows nixos-unstable at every upgrade. A running nixpkgs that
      # is two weeks old means upgrades are not landing, even when none failed.
      build_date=$(${gawk}/bin/awk -F'"' '/^BUILD_ID=/ {split($2, a, "."); print a[3]}' /etc/os-release)
      if [[ "$build_date" =~ ^[0-9]{8}$ ]]; then
        build_epoch=$(${coreutils}/bin/date -d "$build_date" +%s)
        build_age_days=$(( (now_epoch - build_epoch) / 86400 ))
        if [[ "$build_age_days" -ge 14 ]]; then
          record_failure "nixpkgs-stale-''${build_age_days}d"
        fi
      fi

      if [[ -n "''${failures// /}" ]]; then
        notify "paphos health FAIL ($host):$failures"
        exit 1
      fi

      exit 0
    '';

    # loving-kypris liveness, seen from paphos. Two targets: the host itself
    # (LAN ping or SSH on TCP 22, Tailscale ping as a fallback) and Home
    # Assistant (HTTPS on the tailnet name; HA has no LAN port). A target alerts
    # once it has failed for 10 minutes without a break. A normal reboot of
    # loving-kypris takes about 6.5 minutes, so it does not alert. While it stays
    # down, the alert repeats every 2 hours. The first passing sample sends one
    # recovery message with the outage time. No blackout window: the nightly
    # update reboot is exactly the event that hung on 2026-11-02.
    lkLivenessScript = pkgs.writeShellScript "paphos-loving-kypris-liveness" ''
      set -euo pipefail

      token_file="/run/agenix/telegram-lbob-bot-token"
      chat_id="${telegramChatId}"
      state_dir="/var/lib/paphos-lk-liveness"
      now=$(${coreutils}/bin/date +%s)
      alert_after=600
      repeat_after=7200

      # Returns non-zero, and logs why, when Telegram does not accept the
      # message. A failed alert or recovery message is sent again at the next
      # sample, and the unit fails, so the journal shows the gap.
      delivery_failed=false
      notify() {
        local text="$1" answer
        if [[ ! -f "$token_file" ]]; then
          echo "telegram delivery failed: $token_file is missing" >&2
          delivery_failed=true
          return 1
        fi
        answer=$(${curl}/bin/curl -sS --max-time 20 -X POST \
          "https://api.telegram.org/bot$(cat "$token_file")/sendMessage" \
          -d "chat_id=$chat_id" \
          --data-urlencode "text=$text" 2>&1 || true)
        if [[ "$answer" != *'"ok":true'* ]]; then
          echo "telegram delivery failed: ''${answer:0:200}" >&2
          delivery_failed=true
          return 1
        fi
      }

      if [[ "''${1:-}" == --test ]]; then
        notify "TEST: loving-kypris liveness alert path from paphos (no outage)"
        exit $?
      fi

      host_up() {
        ${iputils}/bin/ping -c 2 -W 2 ${lkLanAddress} >/dev/null 2>&1 && return 0
        ${coreutils}/bin/timeout 5 bash -c "exec 3<>/dev/tcp/${lkLanAddress}/22" 2>/dev/null && return 0
        ${tailscaleBin} ping --c 1 --timeout 8s --until-direct=false ${lkTailscaleIp} >/dev/null 2>&1
      }

      ha_up() {
        local code
        code=$(${curl}/bin/curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
          https://${haTailnetName}/manifest.json || true)
        [[ "$code" == 200 ]]
      }

      # One state file per target: "<first failure epoch> <last alert epoch>".
      track() {
        local label="$2" up="$3" file="$state_dir/$1"
        if [[ "$up" == true ]]; then
          if [[ -f "$file" ]]; then
            read -r first alerted <"$file" || true
            if [[ "''${alerted:-0}" -gt 0 ]] &&
              ! notify "loving-kypris RECOVERED: $label back after $(( (now - first) / 60 )) min"; then
              return 0  # keep the file, so the next sample sends the recovery again
            fi
            rm -f "$file"
          fi
          return 0
        fi
        local first alerted=0
        if [[ -f "$file" ]]; then
          read -r first alerted <"$file" || true
        else
          first=$now
        fi
        if (( now - first >= alert_after )) && (( alerted == 0 || now - alerted >= repeat_after )); then
          if notify "loving-kypris DOWN: $label failing for $(( (now - first) / 60 )) min"; then
            alerted=$now
          fi
        fi
        printf '%s %s\n' "$first" "$alerted" >"$file"
        return 1
      }

      status=0
      host=false; host_up && host=true
      track host "host (LAN ping, SSH or Tailscale)" "$host" || status=1
      ha=false; ha_up && ha=true
      track ha "Home Assistant (https://${haTailnetName})" "$ha" || status=1
      if [[ "$delivery_failed" == true ]]; then
        exit 2
      fi
      exit "$status"
    '';

    oracleRelayScript = pkgs.writeShellScript "paphos-oracle-relay-check" ''
      set -euo pipefail

      token_file="/run/agenix/telegram-lbob-bot-token"
      chat_id="${telegramChatId}"
      host="paphos"
      oracle_tailscale_ip="${oracleTailscaleIp}"
      oracle_host="${oracleHost}"
      failures=""

      record_failure() {
        failures="$failures $1"
      }

      notify() {
        local text="$1"
        if [[ -f "$token_file" ]]; then
          ${curl}/bin/curl -fsS -X POST \
            "https://api.telegram.org/bot$(cat "$token_file")/sendMessage" \
            -d "chat_id=$chat_id" \
            --data-urlencode "text=$text" >/dev/null || true
        fi
      }

      if ! ${systemd}/bin/systemctl is-active --quiet tailscaled.service; then
        record_failure tailscaled-local
      else
        ping_ok=false
        for attempt in 1 2 3; do
          if ${tailscaleBin} ping --c 1 --timeout 8s --until-direct=false "$oracle_tailscale_ip" >/dev/null 2>&1; then
            ping_ok=true
            break
          fi
          if [[ "$attempt" -lt 3 ]]; then
            ${coreutils}/bin/sleep 5
          fi
        done
        if [[ "$ping_ok" != true ]]; then
          record_failure "oracle-tailscale-ping-$oracle_tailscale_ip"
        fi

        if ! ${tailscaleBin} status --json \
          | ${jq}/bin/jq -e --arg host "$oracle_host" '
              .Peer[]? | select(.DNSName? // "" | startswith($host))
            ' >/dev/null 2>&1; then
          record_failure oracle-tailscale-status
        fi

        # Reachability above does not prove oracle still serves as a peer relay.
        # `debug` is not stable CLI surface, so a probe that stops parsing is
        # reported separately from a relay that is genuinely gone.
        relay_servers="$(${tailscaleBin} debug peer-relay-servers 2>/dev/null || true)"
        if ! ${jq}/bin/jq -e 'type == "array"' <<<"$relay_servers" >/dev/null 2>&1; then
          record_failure oracle-peer-relay-probe-unavailable
        elif ! ${jq}/bin/jq -e --arg ip "$oracle_tailscale_ip" 'any(.[]?; . == $ip)' \
          <<<"$relay_servers" >/dev/null 2>&1; then
          record_failure "oracle-peer-relay-not-advertised-$oracle_tailscale_ip"
        fi
      fi

      if ! ${coreutils}/bin/timeout 5 bash -c "exec 3<>/dev/tcp/$oracle_host/22" 2>/dev/null; then
        record_failure "oracle-ssh-tcp-$oracle_host"
      fi

      # oracle's own upgrade state, read through the restricted upgrade-status
      # key (modules/oracle/system.nix). Its failures were otherwise silent.
      upgrade_state="$(${openssh}/bin/ssh -i /etc/ssh/ssh_host_ed25519_key \
        -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=10 \
        -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=yes \
        "upgrade-status@$oracle_host" 2>/dev/null || true)"
      case "$upgrade_state" in
        failed) record_failure oracle-nixos-upgrade-failed ;;
        active | activating | inactive | deactivating) ;;
        *) record_failure oracle-nixos-upgrade-status-unavailable ;;
      esac

      if [[ -n "''${failures// /}" ]]; then
        notify "paphos oracle relay FAIL ($host):$failures"
        exit 1
      fi

      exit 0
    '';

    backupScript = pkgs.writeShellScript "paphos-forgejo-backup" ''
      set -euo pipefail

      key_file="/run/agenix/paphos-mother-backup-ssh-key"
      remote_base="${motherBackupBase}"
      remote_host="taohansen@${motherLanAddress}"
      stamp="$(${coreutils}/bin/date -u +%Y%m%dT%H%M%SZ)"
      work_dir="$(${coreutils}/bin/mktemp -d)"
      # Only the pinned key in the global known_hosts counts (programs.ssh.knownHosts.mother).
      ssh_cmd="${openssh}/bin/ssh -i $key_file -o IdentitiesOnly=yes -o BatchMode=yes -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=yes -p 2235"
      trap 'rm -rf "$work_dir"' EXIT

      ${util-linux}/bin/runuser -u postgres -- \
        ${postgresql}/bin/pg_dump forgejo > "$work_dir/forgejo.sql"

      ${gnutar}/bin/tar -C /var/lib --use-compress-program ${gzip}/bin/gzip -cf "$work_dir/forgejo-data.tar.gz" forgejo

      ${coreutils}/bin/install -d -m 0755 "$work_dir/$stamp"
      ${coreutils}/bin/mv "$work_dir/forgejo.sql" "$work_dir/forgejo-data.tar.gz" "$work_dir/$stamp/"
      (
        cd "$work_dir/$stamp"
        ${coreutils}/bin/sha256sum forgejo.sql forgejo-data.tar.gz > SHA256SUMS
      )

      escaped_remote_base=$(${coreutils}/bin/printf '%q' "$remote_base")
      escaped_remote_dir=$(${coreutils}/bin/printf '%q' "$remote_base/$stamp")

      $ssh_cmd "$remote_host" "mkdir -p $escaped_remote_dir && chmod 700 $escaped_remote_base"

      ${rsync}/bin/rsync -av -s -e "$ssh_cmd" "$work_dir/$stamp/" "$remote_host:$remote_base/$stamp/"

      now_epoch=$(${coreutils}/bin/date +%s)
      ${coreutils}/bin/install -d -m 0755 /var/lib/paphos
      echo "$now_epoch" > /var/lib/paphos/forgejo-backup-last-success

      $ssh_cmd "$remote_host" "date -u +%s > $escaped_remote_base/.last-success"
    '';
  in {
    nix.optimise.automatic = true;

    networking.firewall.trustedInterfaces = ["tailscale0"];

    users.groups.fleet-heartbeat = {};
    users.users.fleet-heartbeat = {
      isSystemUser = true;
      group = "fleet-heartbeat";
      home = heartbeatDir;
      createHome = true;
      shell = pkgs.bash;
      openssh.authorizedKeys.keys = [
        ''restrict,from="192.168.99.134,100.80.28.13",command="${coreutils}/bin/date +%s > ${heartbeatDir}/mother-checkpoint" ${motherCheckpointKey}''
      ];
    };

    systemd.services.tailscale-serve-forgejo = {
      description = "Expose Forgejo on Tailscale HTTPS serve";
      after = ["tailscaled.service" "forgejo.service"];
      wants = ["tailscaled.service" "forgejo.service"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [config.services.tailscale.package];
      script = ''
        ${lib.getExe config.services.tailscale.package} serve --bg http://127.0.0.1:3000
      '';
    };

    systemd.services.paphos-forgejo-backup = {
      description = "Backup Forgejo database and data to mother NAS";
      after = ["forgejo.service" "postgresql.service" "network-online.target" "agenix-secrets.target"];
      wants = ["forgejo.service" "postgresql.service" "network-online.target" "agenix-secrets.target"];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
      };
      script = "${backupScript}";
    };

    systemd.timers.paphos-forgejo-backup = {
      description = "Daily Forgejo backup to mother NAS";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
        RandomizedDelaySec = "45min";
      };
    };

    systemd.services.paphos-health-check = {
      description = "paphos health checks with Telegram notification on failure";
      after = ["network-online.target" "agenix-secrets.target"];
      wants = ["network-online.target" "agenix-secrets.target"];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
      };
      script = "${healthScript}";
    };

    systemd.timers.paphos-health-check = {
      description = "Periodic paphos health checks";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "hourly";
        Persistent = true;
        RandomizedDelaySec = "10min";
      };
    };

    # Firmware from LVFS: UEFI dbx and any device firmware a vendor publishes.
    # Capsules install on the next boot, so a pending update gets its own reboot
    # inside the autoUpgrade window, after nixos-upgrade has finished.
    services.fwupd.enable = true;

    systemd.services.paphos-firmware-update = {
      description = "Apply available firmware updates from LVFS";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      path = [config.services.fwupd.package pkgs.python3];
      serviceConfig.Type = "oneshot";
      script = ''
        # fwupdmgr exits 2 when it has nothing to do. Any other non-zero code
        # (no metadata, no network, a failed install) fails the unit, and
        # paphos-health-check reports firmware-update-failed. Before 2026-11-02
        # both calls ended in `|| true`, so this unit reported success after
        # every failure.
        run_fwupdmgr() {
          local code=0
          fwupdmgr "$@" || code=$?
          if [[ "$code" -ne 0 && "$code" -ne 2 ]]; then
            echo "fwupdmgr $1 failed with exit code $code" >&2
            exit "$code"
          fi
        }
        run_fwupdmgr refresh --force
        run_fwupdmgr update --assume-yes --no-reboot-check
        if fwupdmgr get-devices --json | python3 -c 'import json, sys; sys.exit(0 if any(d.get("UpdateState") in (1, 4) for d in json.load(sys.stdin).get("Devices", [])) else 1)'; then
          touch /run/paphos-firmware-reboot
        else
          rm -f /run/paphos-firmware-reboot
        fi
      '';
    };

    systemd.timers.paphos-firmware-update = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "*-*-* 04:30";
        Persistent = true;
      };
    };

    systemd.services.paphos-firmware-reboot = {
      description = "Reboot to install a pending firmware update";
      unitConfig.ConditionPathExists = "/run/paphos-firmware-reboot";
      serviceConfig.Type = "oneshot";
      script = ''
        if systemctl is-active --quiet nixos-upgrade.service; then
          echo "nixos-upgrade is still running; the next window retries"
          exit 0
        fi
        systemctl reboot
      '';
    };

    systemd.timers.paphos-firmware-reboot = {
      wantedBy = ["timers.target"];
      timerConfig.OnCalendar = "*-*-* 06:00";
    };

    systemd.services.paphos-health-check-test = {
      description = "One-shot paphos health check (manual test)";
      after = ["network-online.target" "agenix-secrets.target"];
      wants = ["network-online.target" "agenix-secrets.target"];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
      };
      script = "${healthScript}";
    };

    # Pins oracle's host key for the upgrade-state check above.
    programs.ssh.knownHosts.oracle = {
      hostNames = [oracleHost oracleTailscaleIp];
      publicKey = hostKeys.oracle;
    };

    # Pins mother's host key for the Forgejo backup above.
    programs.ssh.knownHosts.mother = {
      hostNames = ["[${motherLanAddress}]:2235"];
      publicKey = hostKeys.mother;
    };

    systemd.services.paphos-oracle-relay-check = {
      description = "Oracle relay reachability and nixos-upgrade checks with Telegram notification on failure";
      after = ["network-online.target" "tailscaled.service" "agenix-secrets.target"];
      wants = ["network-online.target" "tailscaled.service" "agenix-secrets.target"];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
      };
      path = [config.services.tailscale.package pkgs.bash];
      script = "${oracleRelayScript}";
    };

    systemd.services.paphos-loving-kypris-liveness = {
      description = "loving-kypris host and Home Assistant liveness, with Telegram after 10 minutes down";
      after = ["network-online.target" "tailscaled.service"];
      wants = ["network-online.target"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lkLivenessScript;
        StateDirectory = "paphos-lk-liveness";
      };
    };

    # Sends one TEST message through the same notify() and fails when Telegram
    # does not accept it. Run it by hand after a change to the alert path.
    systemd.services.paphos-loving-kypris-liveness-notify-test = {
      description = "Send one TEST message through the loving-kypris liveness alert path";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lkLivenessScript} --test";
      };
    };

    systemd.timers.paphos-loving-kypris-liveness = {
      description = "Sample loving-kypris liveness every 2 minutes";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "2min";
        AccuracySec = "10s";
      };
    };

    systemd.timers.paphos-oracle-relay-check = {
      description = "Periodic Oracle relay reachability checks from paphos";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "hourly";
        Persistent = true;
        RandomizedDelaySec = "20min";
      };
    };

    systemd.services.paphos-oracle-relay-check-test = {
      description = "One-shot Oracle relay check (manual test)";
      after = ["network-online.target" "tailscaled.service" "agenix-secrets.target"];
      wants = ["network-online.target" "tailscaled.service" "agenix-secrets.target"];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
      };
      path = [config.services.tailscale.package pkgs.bash];
      script = "${oracleRelayScript}";
    };

    age.secrets.paphos-mother-backup-ssh-key = {
      file = ../../secrets/paphos-mother-backup-ssh-key.age;
      mode = "0400";
    };
  };
}
