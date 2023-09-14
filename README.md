# Swarm Extension update for Helix Core SDP Deployments

This is a small change to the Swarm Extension so that large changelists can be
ignored by the extension. This is useful for initial submits of very large projects,
such as Unreal Engine source code.

See Usage below for more information.

## Installation
First, make sure you are logged in to your Helix Core server as a user with 
super access.

From the root of this repository, run the following command:

```
p4 extension --force --allow-unsigned --install swarm-extension-jase.p4-extension -y
```
This will keep your existing configurations in place and just update the extension's code.

## Usage
To tell the extension to ignore your changelist, put one of the following hashtags in your changelist description:
`#noswarm`, `#no-swarm`, `#skipswarm`, `#skip-swarm`

This will completely bypass the Swarm extension so that your changelist is not processed by Swarm at all. This should not be used for anything except for large initial submits that fail for no reason.

This should not be used to bypass workflows in Swarm. If you need to except certain users or paths from Swarm workflows, that can be set in the Swarm web UI.