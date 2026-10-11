# Buzz Codex VPS Course Installer

This repository contains the versioned installer used by the Buzz outreach course. It adds four persistent Codex agents to an existing self-hosted Buzz relay:

- NYC Roofing Researcher
- Outreach Writer
- Fact and Outreach Reviewer
- Campaign Manager

The agents run in separate Docker containers on the VPS. Codex uses ChatGPT device authentication rather than an OpenAI API key. The installer also guides the Campaign Manager through Composio and Gmail authorization.

## Prerequisites

- A fresh Hostinger Buzz deployment that is fully running.
- Relay membership enabled in the Buzz deployment.
- The VPS public IP, `root` username, and root password.
- Your own Buzz relay URL beginning with `wss://`.
- Your Buzz owner public identity as an `npub` or 64-character hexadecimal public key.
- A ChatGPT account with Codex access and device authentication enabled.
- A dedicated test Gmail account and two instructor-controlled recipient inboxes.

Never paste a Buzz private key, `nsec`, password, Codex credential, Gmail token, or API key into Buzz or a course prompt.

## Install version 1.0.0

Connect to the VPS as `root`, then run:

```bash
curl -fL -o /root/install-buzz-codex-vps.sh \
  https://github.com/imaan2005/buzz-codex-course-installer/releases/download/v1.0.0/install-buzz-codex-vps.sh

curl -fL -o /root/SHA256SUMS \
  https://github.com/imaan2005/buzz-codex-course-installer/releases/download/v1.0.0/SHA256SUMS

cd /root
sha256sum -c SHA256SUMS
chmod 700 install-buzz-codex-vps.sh
./install-buzz-codex-vps.sh
```

Follow the prompts shown by the installer. It will pause for ChatGPT device authentication, Buzz community admission, private-channel membership, Composio sign-in, and Gmail authorization.

The installer is intentionally designed for a clean course deployment. It refuses to overwrite an existing four-agent installation.

## What the installer does

- Builds a Codex agent image from a pinned Buzz Sprig image.
- Authenticates Codex through the learner's ChatGPT account.
- Generates four dedicated Buzz identities.
- Waits for the learner to admit the identities through **Settings > Invites**.
- Publishes the four agent profiles.
- Waits for all four agents to be added to the private demonstration channel.
- Starts and verifies four restartable Docker containers.
- Installs Composio only in the Campaign Manager container.
- Guides Gmail authorization and verifies the `GMAIL_SEND_EMAIL` action without sending an email.

## Security and course controls

- Agent private keys and Codex credentials remain on the VPS.
- Each agent has a separate identity, home directory, authentication volume, and workspace.
- Only the Campaign Manager receives Gmail access.
- The controlled demonstration sends exactly two messages to instructor-controlled test inboxes.
- Sending requires the exact Buzz approval message documented in the course.
- The installer does not modify the existing Buzz relay stack intentionally.

## Optional Windows upload helper

`upload-and-run.ps1` remains available for instructors who prefer to run a local copy over one persistent SSH connection. The versioned GitHub release download is the recommended student path.

## Release integrity

Every release includes `SHA256SUMS`. Always download the installer and checksum from the same fixed release version and verify the checksum before execution.
