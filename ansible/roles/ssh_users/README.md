# ssh_users

Manage local admin accounts from inventory: users, authorized keys, sudo
drop-ins and offboarding. Built for the common case of a team without central
identity (no LDAP/SSSD) that still needs to add and remove people cleanly.

What it does:

- Creates users and adds them to a managed group (`sshusers` by default)
- Writes `authorized_keys` **exclusively**, so a key removed from inventory is
  removed from the host
- Installs one sudoers drop-in per user, validated with `visudo` before it lands
- Locks (password locked and account expired) or removes departed users
- Reports members of the managed group that are not in inventory, without
  touching them

Safety checks run on the controller before any host is changed: username and
key format, allowed key types, users listed in two places, and a refusal to
remove or lock the account the play connects as.

## Requirements

- Ansible 2.14+
- `ansible.posix` collection (`ansible-galaxy collection install -r ansible/requirements.yml`)
- `sudo` installed on targets if any user has `sudo` set

## Example

```yaml
# group_vars/all/users.yml
ssh_users_present:
  - name: jdoe
    comment: "Jane Doe"
    sudo: nopasswd
    groups: [docker]
    authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleExampleExampleExampleExample jdoe@laptop

  - name: deploy
    comment: "CI deploy user"
    shell: /bin/bash
    authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAnotherExampleKeyAnotherExampleKey ci@example.com

ssh_users_locked:
  - asmith        # left last week, home dir under review

ssh_users_absent:
  - olduser
```

```bash
ansible-playbook -i inventory ansible/users.yml --check --diff
ansible-playbook -i inventory ansible/users.yml
```

## Variables

| Variable | Default | Notes |
|----------|---------|-------|
| `ssh_users_present` | `[]` | Users to manage; schema in `defaults/main.yml` |
| `ssh_users_absent` | `[]` | Usernames to delete |
| `ssh_users_locked` | `[]` | Usernames to lock and expire, files kept |
| `ssh_users_group` | `sshusers` | Group every managed user joins; usable with sshd `AllowGroups` |
| `ssh_users_exclusive_keys` | `true` | Replace `authorized_keys` with exactly the listed keys |
| `ssh_users_allowed_key_types` | ed25519, ecdsa, sk-*, rsa | Drop `ssh-rsa` once your team has moved off it |
| `ssh_users_remove_home` | `false` | Delete home directory when removing a user |
| `ssh_users_force_remove` | `false` | Pass `--force` to userdel even if the user has processes |
| `ssh_users_report_drift` | `true` | Warn about unmanaged members of the group |

## Tags

`ssh_users_validate`, `ssh_users_keys`, `ssh_users_sudo`, `ssh_users_offboard`,
`ssh_users_drift`. For example, rotate keys only:
`ansible-playbook ansible/users.yml --tags ssh_users_keys`.

## Notes

- Moving a user from `ssh_users_locked` back to `ssh_users_present` clears the
  account expiry so key logins work again. The password stays locked; the role
  never manages passwords.
- `sudo: password` needs the user to have a password set out of band; the role
  never manages passwords.
- Key options (`from="..."`, `command="..."`) are rejected by validation on
  purpose; manage restricted keys separately.
