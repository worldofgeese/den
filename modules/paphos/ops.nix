{den, ...}: let
  motherBackupBase = "/volume1/homes/taohansen/jd/70-79 Operations/71 Server backups/paphos/forgejo";
  telegramChatId = "488228716";
  oracleTailscaleIp = "100.87.121.45";
  oracleHost = "oracle.hound-celsius.ts.net";
in {
  den.aspects.paphos.nixos = {
    config,
    lib,
    pkgs,
    ...
  }: let
    inherit (pkgs) coreutils curl gawk gzip gnutar jq openssh postgresql rsync systemd util-linux;
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

      if ${systemd}/bin/systemctl list-unit-files forgesync-github.timer >/dev/null 2>&1; then
        if ! ${systemd}/bin/systemctl is-active --quiet forgesync-github.timer; then
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

      if [[ -n "''${failures// /}" ]]; then
        notify "paphos health FAIL ($host):$failures"
        exit 1
      fi

      exit 0
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
          if ${tailscaleBin} ping --c 1 --timeout 8s "$oracle_tailscale_ip" >/dev/null 2>&1; then
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
      fi

      if ! ${coreutils}/bin/timeout 5 bash -c "exec 3<>/dev/tcp/$oracle_host/22" 2>/dev/null; then
        record_failure "oracle-ssh-tcp-$oracle_host"
      fi

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
      remote_host="taohansen@mother.hound-celsius.ts.net"
      stamp="$(${coreutils}/bin/date -u +%Y%m%dT%H%M%SZ)"
      work_dir="$(${coreutils}/bin/mktemp -d)"
      ssh_cmd="${openssh}/bin/ssh -i $key_file -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new -p 2235"
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

    systemd.services.paphos-oracle-relay-check = {
      description = "Oracle tailnet relay reachability checks with Telegram notification on failure";
      after = ["network-online.target" "tailscaled.service" "agenix-secrets.target"];
      wants = ["network-online.target" "tailscaled.service" "agenix-secrets.target"];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
      };
      path = [config.services.tailscale.package pkgs.bash];
      script = "${oracleRelayScript}";
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
