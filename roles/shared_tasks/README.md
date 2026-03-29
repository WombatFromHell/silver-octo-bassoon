# Shared Task Library

This role provides reusable task files for common patterns across all roles.

## Usage

Import tasks using `ansible.builtin.import_tasks` or `ansible.builtin.include_tasks`:

```yaml
- name: Install a script
  ansible.builtin.import_tasks: install_script.yml
  vars:
    src: "{{ role_path }}/files/myscript.sh"
    dest: "/usr/local/bin/myscript"
    mode: "0755"

- name: Install a config file
  ansible.builtin.import_tasks: install_config.yml
  vars:
    src: "{{ role_path }}/files/myapp.conf"
    dest: "/etc/myapp/config.conf"
    validate: "myapp --check %s"

- name: Manage a service
  ansible.builtin.import_tasks: manage_service.yml
  vars:
    service_name: myservice
    state: started
    enabled: true

- name: Install packages
  ansible.builtin.import_tasks: install_packages.yml
  vars:
    packages: [pkg1, pkg2, pkg3]
    package_manager: pacman

- name: Create a symlink
  ansible.builtin.import_tasks: create_symlink.yml
  vars:
    src: /path/to/source
    dest: /path/to/link

- name: Check if command exists
  ansible.builtin.import_tasks: command_exists.yml
  vars:
    command: myapp
    register_var: myapp_check_result

- name: Validate required variables
  ansible.builtin.import_tasks: validate_vars.yml
  vars:
    required_vars:
      - my_required_var
      - another_required_var
```

## Available Tasks

| Task | Description |
|------|-------------|
| `install_script.yml` | Install script with proper permissions |
| `install_config.yml` | Install config file with backup |
| `manage_service.yml` | Enable/start/restart systemd services |
| `install_packages.yml` | Install packages with error handling |
| `create_symlink.yml` | Create symlinks with verification |
| `command_exists.yml` | Check if command exists in PATH |
| `validate_vars.yml` | Validate required variables are defined |

## Benefits

1. **Consistency**: Same pattern used everywhere
2. **Error Handling**: Built-in validation and error reporting
3. **Idempotency**: Proper `changed_when` and `failed_when`
4. **Maintainability**: Fix once, benefits all roles
5. **Documentation**: Self-documenting task usage
