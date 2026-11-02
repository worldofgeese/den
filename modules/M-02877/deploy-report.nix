# The deploy report of plan step P8 (docs/plans/2026-10-30-001-dagger-ci-autonomous-merge-plan.md).
#
# Each morning, after the server upgrade windows (paphos 05:00-06:30), the agent
# reads what each den host runs and keeps one GitHub issue per failing step.
# It uses the gh login and the SSH configuration of dktaohan, so it runs as a
# user agent. A run that cannot reach a host opens `deploy: <host>: unreachable`
# and closes nothing for that host.
{
  den.aspects.M-02877.darwin = {
    config,
    pkgs,
    ...
  }: let
    home = config.users.users.dktaohan.home;
    report = pkgs.writeShellApplication {
      name = "den-deploy-report";
      runtimeInputs = [pkgs.python3 pkgs.gh pkgs.coreutils];
      text = ''
        exec python3 ${../../scripts/deploy-report.py} "$@"
      '';
    };
  in {
    environment.systemPackages = [report];
    launchd.user.agents.den-deploy-report.serviceConfig = {
      Label = "com.dktaohan.den-deploy-report";
      ProgramArguments = ["${report}/bin/den-deploy-report"];
      # /usr/bin first: the system ssh uses the Keychain-backed agent and
      # ~/.ssh/config with the pinned known_hosts of the den hosts.
      EnvironmentVariables.PATH = "/usr/bin:/bin:/usr/sbin:/sbin:/run/current-system/sw/bin";
      StartCalendarInterval = [
        {
          Hour = 8;
          Minute = 15;
        }
      ];
      StandardOutPath = "${home}/Library/Logs/den-deploy-report.log";
      StandardErrorPath = "${home}/Library/Logs/den-deploy-report.log";
    };
  };
}
