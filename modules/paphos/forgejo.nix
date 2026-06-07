{
  den,
  inputs,
  ...
}: {
  den.aspects.paphos.nixos = {
    config,
    pkgs,
    ...
  }: {
    imports = [
      inputs.forgesync.nixosModules.default
      inputs.agenix.nixosModules.default
    ];

    services.forgejo = {
      package = pkgs.forgejo;
      enable = true;
      database.type = "postgres";
      lfs.enable = true;
      settings = {
        server = {
          DOMAIN = "paphos.hound-celsius.ts.net";
          ROOT_URL = "https://paphos.hound-celsius.ts.net/";
          HTTP_PORT = 3000;
          SSH_PORT = 22;
        };
        service.DISABLE_REGISTRATION = true;
        session.COOKIE_SECURE = true;
      };
    };

    services.forgesync = {
      enable = true;
      jobs.github = {
        source = "https://paphos.hound-celsius.ts.net/api/v1";
        target = "github";
        settings = {
          remirror = true;
          description-template = "{description} (Mirror of {url})";
          feature = ["issues" "pull-requests"];
          mirror-interval = "8h0m0s";
          log = "INFO";
          exclude = ["goetia-dashboard" "openclaw-config" "kypris-workspace" "meridian" "form-bus"];
        };
        secretFile = "/etc/forgesync/github.env";
        timerConfig = {
          OnCalendar = "daily";
          Persistent = true;
        };
      };
    };

    age.secrets = {
      forgejo-admin-password = {
        file = ../../secrets/forgejo-admin-password.age;
        owner = "kypris";
        group = "users";
      };
      forgesync-forgejo-token = {
        file = ../../secrets/forgesync-forgejo-token.age;
        owner = "kypris";
        group = "users";
      };
      forgesync-github-pat = {
        file = ../../secrets/forgesync-github-pat.age;
        owner = "kypris";
        group = "users";
      };
      aws-access-key-id = {
        file = ../../secrets/aws-access-key-id.age;
        owner = "kypris";
        group = "users";
      };
      aws-secret-access-key = {
        file = ../../secrets/aws-secret-access-key.age;
        owner = "kypris";
        group = "users";
      };
      mediawiki-bot-password = {
        file = ../../secrets/mediawiki-bot-password.age;
        owner = "kypris";
        group = "users";
      };
      mochi-api-key = {
        file = ../../secrets/mochi-api-key.age;
        owner = "kypris";
        group = "users";
      };
      skillsmp-api-key = {
        file = ../../secrets/skillsmp-api-key.age;
        owner = "kypris";
        group = "users";
      };
      groq-api-key = {
        file = ../../secrets/groq-api-key.age;
        owner = "kypris";
        group = "users";
      };
      telegram-lbob-bot-token = {
        file = ../../secrets/telegram-lbob-bot-token.age;
        owner = "kypris";
        group = "users";
      };
      surge-email = {
        file = ../../secrets/surge-email.age;
        owner = "kypris";
        group = "users";
      };
      surge-password = {
        file = ../../secrets/surge-password.age;
        owner = "kypris";
        group = "users";
      };
    };
  };
}
