#
# Build with "nix-build -A pkgname"
#
{ system ? builtins.currentSystem
, srcpath ? ""
, manifest ? ""
, manifest_json ? ""
, channel_json ? null
# The name of this channel
, channelName ? baseNameOf ./.
, debugVerbosity ? 0
}:

let

  # We only import nixpkgs once with an overlay that adds all channels, which is
  # also used as a base set for all channels themselves
  pkgs = import <nixpkgs> {
    inherit system;
    overlays = [(self: super: {
      inherit floxChannels;
    })];
  };

  inherit (pkgs) lib;

  withVerbosity = level: fun: val: if debugVerbosity >= level then fun val else val;

  # A mapping from channel name to channel source, as given by the channel_json
  channelSources = if channel_json == null then {} else
    lib.mapAttrs (name: args:
      # For debugging, allow channel_json to specify paths directly
      if ! lib.isAttrs args then args
      else pkgs.fetchgit {
        inherit (args) url rev sha256 fetchSubmodules;
      }
    ) (lib.importJSON channel_json);

  # Imports the channel from a source, adding extra attributes to its scope
  importChannel = name: src: extraAttrs:
    let
      # Allow channels to add nixpkgs overlays to their base pkgs. This also
      # allows channels to override other channels since pkgs.channelPkgs can be
      # changed via overlays
      channelPkgs = if builtins.pathExists (src + "/nixpkgs-overlay.nix")
        then pkgs.extend (import (src + "/nixpkgs-overlay.nix"))
        else pkgs;

      channelPkgs' = withVerbosity 6
        (lib.mapAttrsRecursiveCond
          (value: ! lib.isDerivation value)
          (path: builtins.trace "Channel `${name}` is evaluating nixpkgs attribute ${lib.concatStringsSep "." path}"))
        # Remove floxChannels as we modify them slightly for access by other channels
        # Don't let nixpkgs override our own extend
        # Remove appendOverlays as it doesn't use the current overlay chain
        (removeAttrs channelPkgs [ "floxChannels" "extend" "appendOverlays" ]);

      # Traces evaluation of another channel accessed from this one
      subchannelTrace = subname:
        withVerbosity 2 (builtins.trace "Accessing channel `${subname}` from `${name}`")
          (withVerbosity 3
            (lib.mapAttrsRecursiveCond
              (value: ! lib.isDerivation value)
              (path: builtins.trace "Evaluating channel `${subname}` attribute `${lib.concatStringsSep "." path}` from channel `${name}`")));

      # Each channel can refer to other channels via their names. This defines
      # the name -> channel mapping
      floxChannels' = self: lib.mapAttrs (subname: value:
        subchannelTrace subname
        # Propagate the channel config down to all channels
        # And only expose the finalResult attribute so only the explicitly exposed attributes can be accessed
        (value.withChannelConfig self.channelConfig).finalResult
      ) channelPkgs.floxChannels;

      # A custom lib.extends function that can emit debug information for what attributes each overlay adds
      extends = overlay: fun: self:
        let
          super = fun self;
          overlayResult = overlay self super;
        in super // withVerbosity 5
          (builtins.trace "Channel `${name}` applies an overlay with attributes: ${lib.concatStringsSep ", " (lib.attrNames overlayResult)}")
          overlayResult;

      # A function that returns the channel package set with the given overlays applied
      withOverlays = overlays:
        let
          # The main self-referential package set function
          baseFun = self:
            # Add all nixpkgs packages
            channelPkgs'
            # Expose all channels as attributes
            // floxChannels' self
            // {
              # The withVerbosity function for other overlays being able to emit debug traces
              inherit withVerbosity;
              # Channel name for debugging
              channelName = name;

              # Allow adding extra overlays on top
              # Note that this is an expensive operation and should be avoided using when possible
              extend = extraOverlays: withOverlays (overlays ++ lib.toList extraOverlays);
            }
            # Any extra attributes passed
            // extraAttrs;
        in lib.fix (lib.foldl' (lib.flip extends) baseFun overlays);

      # Apply all the channels overlays to the scope
      finalScope =
        if builtins.pathExists (src + "/overlays.nix")
        then withOverlays (import (src + "/overlays.nix"))
        else throw ("Channel `${name}` can't be imported from `${toString src}`"
          + " because it doesn't have an `./overlays.nix` file, indicating that"
          + " it's using an outdated nixexprs-proto version");

    in withVerbosity 1
      (builtins.trace "Importing channel `${name}` from `${toString src}`")
      finalScope;

  # The channel mapping to be passed into nixpkgs. This also allows nixpkgs
  # overlays to deeply override packages with channel versions
  floxChannels = lib.mapAttrs (name: src: importChannel name src {}) channelSources // {

    # Override our own channel to the current directory
    ${channelName} = importChannel channelName ./. {
      # Pass the arguments that were passed to this channel into the scope
      # These are used by floxSetSrcVersion.nix
      args = {
        inherit srcpath manifest manifest_json;
      };
    };

  };

in pkgs.floxChannels.${channelName}.finalResult // {
  unfiltered = pkgs.floxChannels.${channelName};
}
