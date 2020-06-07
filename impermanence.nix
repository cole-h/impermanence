{ pkgs, config, lib, ... }:
let
  cfg = config.environment.impermanence;

  persistentStoragePaths = lib.attrNames cfg;
in
{
  options.environment.impermanence = lib.mkOption {
    default = { };
    type = with lib.types; attrsOf (
      submodule {
        options = {
          files = lib.mkOption {
            type = with lib.types; listOf str;
            default = [ ];
            description = "Files to bind mount to persistent storage.";
          };

          directories = lib.mkOption {
            type = with lib.types; listOf str;
            default = [ ];
            description = "Directories to bind mount to persistent storage.";
          };
        };
      }
    );
  };

  config = {
    fileSystems =
      let
        # Function to create fileSystem bind mount entries
        mkBindMountNameValuePair = persistentStoragePath: path: {
          name = "${path}";
          value = {
            device = "${persistentStoragePath}${path}";
            options = [ "bind" ];
            noCheck = true;
          };
        };

        # Function to build the bind mounts for files and directories
        mkBindMounts = persistentStoragePath:
          lib.listToAttrs (map
            (mkBindMountNameValuePair persistentStoragePath)
            (cfg.${persistentStoragePath}.files ++
              cfg.${persistentStoragePath}.directories)
          );
      in
      lib.foldl' lib.recursiveUpdate { } (map mkBindMounts persistentStoragePaths);

    system.activationScripts =
      let
        # Function to create a directory in both the place where we want
        # to bind mount it as well as making sure it exists in the location
        # where persistence is located. This also enforces the correct ownership
        # of the directory structure.
        mkDirCreationSnippet = persistentStoragePath: dir:
          ''
            # capture the nix vars into bash to avoid escape hell
            sourceBase="${persistentStoragePath}"
            target="${dir}"

            # trim trailing slashes the root of all evil
            sourceBase="''${sourceBase%/}"
            target="''${target%/}"

            # iterate over each part of the target path
            previousPath="/"
            for pathPart in $(echo "$target" | tr "/" " "); do
              # construct the incremental path, e.g. /var, /var/lib, /var/lib/iwd
              currentTargetPath="$previousPath$pathPart/"

              # construct the source path, e.g. /state/var, /state/var/lib
              currentSourcePath="$sourceBase$currentTargetPath"

              if [ ! -d "$currentSourcePath" ]; then
                printf "Bind source '%s' does not exist, creating it\n" "$currentSourcePath"
                mkdir "$currentSourcePath"
              fi
              if [ ! -d "$currentTargetPath" ]; then
                mkdir "$currentTargetPath"
              fi

              # synchronize perms between the two, should be a noop if they were
              # both just created.
              chown --reference="$currentSourcePath" "$currentTargetPath"
              chmod --reference="$currentSourcePath" "$currentTargetPath"

              # lastly we update the previousPath to continue down the tree
              previousPath="$currentTargetPath"

              unset currentSourcePath
              unset currentTargetPath
            done

            unset previousPath
            unset sourceBase
            unset target
          '';

        # Function to create a file in both the place where we want to bind
        # mount it as well as making sure it exists in the location where
        # persistence is located. This is simply mkDirCreationSnippet on the
        # dirname with a touch and chown.
        mkFileCreationSnippet = persistentStoragePath: file:
          ''
            # replicate the directory structure of ${file}
            ${mkDirCreationSnippet persistentStoragePath (dirOf file)}

            # now create the source and target, if they don't exist
            sourcePath="${persistentStoragePath}${file}"
            targetPath="${file}"
            if [ ! -f "$sourcePath" ]; then
              touch "$sourcePath"
            fi
            if [ ! -f "$targetPath" ]; then
              touch "$targetPath"
            fi

            # synchronize perms between the two, should be a noop if they were
            # both just created.
            chown --reference="$sourcePath" "$targetPath"
            chmod --reference="$sourcePath" "$targetPath"

            unset sourcePath
            unset targetPath
          '';

        # Function to build the activation script string for creating files
        # and directories as part of the activation script.
        mkFileActivationScripts = persistentStoragePath:
          lib.nameValuePair
            "createFilesAndDirsIn-${lib.replaceStrings [ "/" "." " " ] [ "-" "-" "-" ] persistentStoragePath}"
            (lib.noDepEntry (lib.concatStrings [
              # Create activation scripts for files
              (lib.concatMapStrings
                (mkFileCreationSnippet persistentStoragePath)
                cfg.${persistentStoragePath}.files
              )

              # Create activation scripts for directories
              (lib.concatMapStrings
                (mkDirCreationSnippet persistentStoragePath)
                cfg.${persistentStoragePath}.directories
              )
            ]));

      in
      lib.listToAttrs (map mkFileActivationScripts persistentStoragePaths);

    # Assert that all filesystems that we used are marked with neededForBoot.
    assertions =
      let
        assertTest = cond: fs: (config.fileSystems.${fs}.neededForBoot == cond);
      in
      [{
        assertion = lib.all (assertTest true) persistentStoragePaths;
        message =
          let
            offenders = lib.filter (assertTest false) persistentStoragePaths;
          in
          ''
            environment.impermanence:
              All filesystems used to back must have the flag neededForBoot
              set to true.

            Please fix / remove the following paths:
              ${lib.concatStringsSep "\n      " offenders}
          '';
      }];
  };
}
