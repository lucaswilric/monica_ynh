#!/bin/bash


pkg_dependencies="php7.2-cli php7.2-json php7.2-opcache php7.2-mysql php7.2-mbstring php7.2-zip php7.2-bcmath php7.2-intl php7.2-xml php7.2-curl php7.2-gd php7.2-gmp"


# Execute a command with Composer
#
# usage: ynh_composer_exec --phpversion=phpversion [--workdir=$final_path] --commands="commands"
# | arg: -w, --workdir - The directory from where the command will be executed. Default $final_path.
# | arg: -c, --commands - Commands to execute.
ynh_composer_exec () {
	# Declare an array to define the options of this helper.
	local legacy_args=vwc
	declare -Ar args_array=( [v]=phpversion= [w]=workdir= [c]=commands= )
	local phpversion
	local workdir
	local commands
	# Manage arguments with getopts
	ynh_handle_getopts_args "$@"
	workdir="${workdir:-$final_path}"
	phpversion="${phpversion:-7.0}"

	COMPOSER_HOME="$workdir/.composer" \
		php${phpversion} "$workdir/composer.phar" $commands \
		-d "$workdir" --quiet --no-interaction
}

# Install and initialize Composer in the given directory
#
# usage: ynh_install_composer --phpversion=phpversion [--workdir=$final_path]
# | arg: -w, --workdir - The directory from where the command will be executed. Default $final_path.
ynh_install_composer () {
	# Declare an array to define the options of this helper.
	local legacy_args=vw
	declare -Ar args_array=( [v]=phpversion= [w]=workdir= )
	local phpversion
	local workdir
	# Manage arguments with getopts
	ynh_handle_getopts_args "$@"
	workdir="${workdir:-$final_path}"
	phpversion="${phpversion:-7.0}"

	curl -sS https://getcomposer.org/installer \
		| COMPOSER_HOME="$workdir/.composer" \
		php${phpversion} -- --quiet --install-dir="$workdir" \
		|| ynh_die "Unable to install Composer."

	# update dependencies to create composer.lock
	ynh_composer_exec --phpversion="${phpversion}" --workdir="$workdir" --commands="install --no-dev" \
		|| ynh_die "Unable to update core dependencies with Composer."
}


# Create a dedicated php-fpm config
#
# usage 1: ynh_add_fpm_config [--phpversion=7.X] [--use_template] [--package=packages] [--dedicated_service]
# | arg: -v, --phpversion=          - Version of php to use.
# | arg: -t, --use_template         - Use this helper in template mode.
# | arg: -p, --package=             - Additionnal php packages to install
# | arg: -d, --dedicated_service    - Use a dedicated php-fpm service instead of the common one.
#
# -----------------------------------------------------------------------------
#
# usage 2: ynh_add_fpm_config [--phpversion=7.X] --usage=usage --footprint=footprint [--package=packages] [--dedicated_service]
# | arg: -v, --phpversion=          - Version of php to use.
# | arg: -f, --footprint=           - Memory footprint of the service (low/medium/high).
# low    - Less than 20Mb of ram by pool.
# medium - Between 20Mb and 40Mb of ram by pool.
# high   - More than 40Mb of ram by pool.
# Or specify exactly the footprint, the load of the service as Mb by pool instead of having a standard value.
# To have this value, use the following command and stress the service.
# watch -n0.5 ps -o user,cmd,%cpu,rss -u APP
#
# | arg: -u, --usage=               - Expected usage of the service (low/medium/high).
# low    - Personal usage, behind the sso.
# medium - Low usage, few people or/and publicly accessible.
# high   - High usage, frequently visited website.
#
# | arg: -p, --package=             - Additionnal php packages to install for a specific version of php
# | arg: -d, --dedicated_service    - Use a dedicated php-fpm service instead of the common one.
#
#
# The footprint of the service will be used to defined the maximum footprint we can allow, which is half the maximum RAM.
# So it will be used to defined 'pm.max_children'
# A lower value for the footprint will allow more children for 'pm.max_children'. And so for
#    'pm.start_servers', 'pm.min_spare_servers' and 'pm.max_spare_servers' which are defined from the
#    value of 'pm.max_children'
# NOTE: 'pm.max_children' can't exceed 4 times the number of processor's cores.
#
# The usage value will defined the way php will handle the children for the pool.
# A value set as 'low' will set the process manager to 'ondemand'. Children will start only if the
#   service is used, otherwise no child will stay alive. This config gives the lower footprint when the
#   service is idle. But will use more proc since it has to start a child as soon it's used.
# Set as 'medium', the process manager will be at dynamic. If the service is idle, a number of children
#   equal to pm.min_spare_servers will stay alive. So the service can be quick to answer to any request.
#   The number of children can grow if needed. The footprint can stay low if the service is idle, but
#   not null. The impact on the proc is a little bit less than 'ondemand' as there's always a few
#   children already available.
# Set as 'high', the process manager will be set at 'static'. There will be always as many children as
#   'pm.max_children', the footprint is important (but will be set as maximum a quarter of the maximum
#   RAM) but the impact on the proc is lower. The service will be quick to answer as there's always many
#   children ready to answer.
#
# Requires YunoHost version 2.7.2 or higher.
# Requires YunoHost version 3.5.1 or higher for the argument --phpversion
# Requires YunoHost version 3.8.1 or higher for the arguments --use_template, --usage, --footprint, --package and --dedicated_service
ynh_add_fpm_config () {
    # Declare an array to define the options of this helper.
    local legacy_args=vtufpd
    local -A args_array=( [v]=phpversion= [t]=use_template [u]=usage= [f]=footprint= [p]=package= [d]=dedicated_service )
    local phpversion
    local use_template
    local usage
    local footprint
    local package
    local dedicated_service
    # Manage arguments with getopts
    ynh_handle_getopts_args "$@"
    package=${package:-}

    # The default behaviour is to use the template.
    use_template="${use_template:-1}"
    usage="${usage:-}"
    footprint="${footprint:-}"
    if [ -n "$usage" ] || [ -n "$footprint" ]; then
        use_template=0
    fi
    # Do not use a dedicated service by default
    dedicated_service=${dedicated_service:-0}

    # Set the default PHP-FPM version by default
    phpversion="${phpversion:-$YNH_PHP_VERSION}"

    # If the requested php version is not the default version for YunoHost
    if [ "$phpversion" != "$YNH_DEFAULT_PHP_VERSION" ]
    then
        # If the argument --package is used, add the packages to ynh_install_php to install them from sury
        if [ -n "$package" ]
        then
            local additionnal_packages="--package=$package"
        else
            local additionnal_packages=""
        fi
        # Install this specific version of php.
        ynh_install_php --phpversion="$phpversion" "$additionnal_packages"
    elif [ -n "$package" ]
    then
        # Install the additionnal packages from the default repository
        ynh_add_app_dependencies --package="$package"
    fi

    if [ $dedicated_service -eq 1 ]
    then
        local fpm_service="${app}-phpfpm"
        local fpm_config_dir="/etc/php/$phpversion/dedicated-fpm"
    else
        local fpm_service="php${phpversion}-fpm"
        local fpm_config_dir="/etc/php/$phpversion/fpm"
    fi
    # Configure PHP-FPM 5 on Debian Jessie
    if [ "$(ynh_get_debian_release)" == "jessie" ]
    then
        fpm_config_dir="/etc/php5/fpm"
        fpm_service="php5-fpm"
    fi

    # Create the directory for fpm pools
    mkdir --parents "$fpm_config_dir/pool.d"

    ynh_app_setting_set --app=$app --key=fpm_config_dir --value="$fpm_config_dir"
    ynh_app_setting_set --app=$app --key=fpm_service --value="$fpm_service"
    ynh_app_setting_set --app=$app --key=fpm_dedicated_service --value="$dedicated_service"
    ynh_app_setting_set --app=$app --key=phpversion --value=$phpversion
    finalphpconf="$fpm_config_dir/pool.d/$app.conf"

    # Migrate from mutual php service to dedicated one.
    if [ $dedicated_service -eq 1 ]
    then
        local old_fpm_config_dir="/etc/php/$phpversion/fpm"
        # If a config file exist in the common pool, move it.
        if [ -e "$old_fpm_config_dir/pool.d/$app.conf" ]
        then
            ynh_print_info --message="Migrate to a dedicated php-fpm service for $app."
            # Create a backup of the old file before migration
            ynh_backup_if_checksum_is_different --file="$old_fpm_config_dir/pool.d/$app.conf"
            # Remove the old php config file
            ynh_secure_remove --file="$old_fpm_config_dir/pool.d/$app.conf"
            # Reload php to release the socket and allow the dedicated service to use it
            ynh_systemd_action --service_name=php${phpversion}-fpm --action=reload
        fi
    fi

    ynh_backup_if_checksum_is_different --file="$finalphpconf"

    if [ $use_template -eq 1 ]
    then
        # Usage 1, use the template in ../conf/php-fpm.conf
        cp ../conf/php-fpm.conf "$finalphpconf"
        ynh_replace_string --match_string="__NAMETOCHANGE__" --replace_string="$app" --target_file="$finalphpconf"
        ynh_replace_string --match_string="__FINALPATH__" --replace_string="$final_path" --target_file="$finalphpconf"
        ynh_replace_string --match_string="__USER__" --replace_string="$app" --target_file="$finalphpconf"
        ynh_replace_string --match_string="__PHPVERSION__" --replace_string="$phpversion" --target_file="$finalphpconf"

    else
        # Usage 2, generate a php-fpm config file with ynh_get_scalable_phpfpm

        # Store settings
        ynh_app_setting_set --app=$app --key=fpm_footprint --value=$footprint
        ynh_app_setting_set --app=$app --key=fpm_usage --value=$usage

        # Define the values to use for the configuration of php.
        ynh_get_scalable_phpfpm --usage=$usage --footprint=$footprint

        # Copy the default file
        cp "/etc/php/$phpversion/fpm/pool.d/www.conf" "$finalphpconf"

        # Replace standard variables into the default file
        ynh_replace_string --match_string="^\[www\]" --replace_string="[$app]" --target_file="$finalphpconf"
        ynh_replace_string --match_string=".*listen = .*" --replace_string="listen = /var/run/php/php$phpversion-fpm-$app.sock" --target_file="$finalphpconf"
        ynh_replace_string --match_string="^user = .*" --replace_string="user = $app" --target_file="$finalphpconf"
        ynh_replace_string --match_string="^group = .*" --replace_string="group = $app" --target_file="$finalphpconf"
        ynh_replace_string --match_string=".*chdir = .*" --replace_string="chdir = $final_path" --target_file="$finalphpconf"

        # Configure fpm children
        ynh_replace_string --match_string=".*pm = .*" --replace_string="pm = $php_pm" --target_file="$finalphpconf"
        ynh_replace_string --match_string=".*pm.max_children = .*" --replace_string="pm.max_children = $php_max_children" --target_file="$finalphpconf"
        ynh_replace_string --match_string=".*pm.max_requests = .*" --replace_string="pm.max_requests = 500" --target_file="$finalphpconf"
        ynh_replace_string --match_string=".*request_terminate_timeout = .*" --replace_string="request_terminate_timeout = 1d" --target_file="$finalphpconf"
        if [ "$php_pm" = "dynamic" ]
        then
            ynh_replace_string --match_string=".*pm.start_servers = .*" --replace_string="pm.start_servers = $php_start_servers" --target_file="$finalphpconf"
            ynh_replace_string --match_string=".*pm.min_spare_servers = .*" --replace_string="pm.min_spare_servers = $php_min_spare_servers" --target_file="$finalphpconf"
            ynh_replace_string --match_string=".*pm.max_spare_servers = .*" --replace_string="pm.max_spare_servers = $php_max_spare_servers" --target_file="$finalphpconf"
        elif [ "$php_pm" = "ondemand" ]
        then
            ynh_replace_string --match_string=".*pm.process_idle_timeout = .*" --replace_string="pm.process_idle_timeout = 10s" --target_file="$finalphpconf"
        fi

        # Comment unused parameters
        if [ "$php_pm" != "dynamic" ]
        then
            ynh_replace_string --match_string=".*\(pm.start_servers = .*\)" --replace_string=";\1" --target_file="$finalphpconf"
            ynh_replace_string --match_string=".*\(pm.min_spare_servers = .*\)" --replace_string=";\1" --target_file="$finalphpconf"
            ynh_replace_string --match_string=".*\(pm.max_spare_servers = .*\)" --replace_string=";\1" --target_file="$finalphpconf"
        fi
        if [ "$php_pm" != "ondemand" ]
        then
            ynh_replace_string --match_string=".*\(pm.process_idle_timeout = .*\)" --replace_string=";\1" --target_file="$finalphpconf"
        fi

        # Concatene the extra config.
        if [ -e ../conf/extra_php-fpm.conf ]; then
            cat ../conf/extra_php-fpm.conf >> "$finalphpconf"
        fi
    fi

    chown root: "$finalphpconf"
    ynh_store_file_checksum --file="$finalphpconf"

    if [ -e "../conf/php-fpm.ini" ]
    then
        ynh_print_warn -message="Packagers ! Please do not use a separate php ini file, merge your directives in the pool file instead."
        finalphpini="$fpm_config_dir/conf.d/20-$app.ini"
        ynh_backup_if_checksum_is_different "$finalphpini"
        cp ../conf/php-fpm.ini "$finalphpini"
        chown root: "$finalphpini"
        ynh_store_file_checksum "$finalphpini"
    fi

    if [ $dedicated_service -eq 1 ]
    then
        # Create a dedicated php-fpm.conf for the service
        local globalphpconf=$fpm_config_dir/php-fpm-$app.conf
        cp /etc/php/${phpversion}/fpm/php-fpm.conf $globalphpconf

        ynh_replace_string --match_string="^[; ]*pid *=.*" --replace_string="pid = /run/php/php${phpversion}-fpm-$app.pid" --target_file="$globalphpconf"
        ynh_replace_string --match_string="^[; ]*error_log *=.*" --replace_string="error_log = /var/log/php/fpm-php.$app.log" --target_file="$globalphpconf"
        ynh_replace_string --match_string="^[; ]*syslog.ident *=.*" --replace_string="syslog.ident = php-fpm-$app" --target_file="$globalphpconf"
        ynh_replace_string --match_string="^[; ]*include *=.*" --replace_string="include = $finalphpconf" --target_file="$globalphpconf"

        # Create a config for a dedicated php-fpm service for the app
        echo "[Unit]
Description=PHP $phpversion FastCGI Process Manager for $app
After=network.target
[Service] 
Type=notify
PIDFile=/run/php/php${phpversion}-fpm-$app.pid
ExecStart=/usr/sbin/php-fpm$phpversion --nodaemonize --fpm-config $globalphpconf
ExecReload=/bin/kill -USR2 \$MAINPID
[Install]
WantedBy=multi-user.target
" > ../conf/$fpm_service

        # Create this dedicated php-fpm service
        ynh_add_systemd_config --service=$fpm_service --template=$fpm_service
        # Integrate the service in YunoHost admin panel
        yunohost service add $fpm_service --log /var/log/php/fpm-php.$app.log --log_type file --description "Php-fpm dedicated to $app"
        # Configure log rotate
        ynh_use_logrotate --logfile=/var/log/php
        # Restart the service, as this service is either stopped or only for this app
        ynh_systemd_action --service_name=$fpm_service --action=restart
    else
        # Reload php, to not impact other parts of the system using php
        ynh_systemd_action --service_name=$fpm_service --action=reload
    fi
}

# Remove the dedicated php-fpm config
#
# usage: ynh_remove_fpm_config
#
# Requires YunoHost version 2.7.2 or higher.
ynh_remove_fpm_config () {
    local fpm_config_dir=$(ynh_app_setting_get --app=$app --key=fpm_config_dir)
    local fpm_service=$(ynh_app_setting_get --app=$app --key=fpm_service)
    local dedicated_service=$(ynh_app_setting_get --app=$app --key=fpm_dedicated_service)
    dedicated_service=${dedicated_service:-0}
    # Get the version of php used by this app
    local phpversion=$(ynh_app_setting_get $app phpversion)

    # Assume default PHP-FPM version by default
    phpversion="${phpversion:-$YNH_DEFAULT_PHP_VERSION}"

    # Assume default php files if not set
    if [ -z "$fpm_config_dir" ]
    then
        fpm_config_dir="/etc/php/$YNH_DEFAULT_PHP_VERSION/fpm"
        fpm_service="php$YNH_DEFAULT_PHP_VERSION-fpm"
    fi

    if [ $dedicated_service -eq 1 ]
    then
        # Remove the dedicated service php-fpm service for the app
        ynh_remove_systemd_config --service=$fpm_service
        # Remove the global php-fpm conf
        ynh_secure_remove --file="$fpm_config_dir/php-fpm-$app.conf"
        # Remove the service from the list of services known by Yunohost
        yunohost service remove $fpm_service
    elif ynh_package_is_installed --package="php${phpversion}-fpm"; then
        ynh_systemd_action --service_name=$fpm_service --action=reload
    fi

    ynh_secure_remove --file="$fpm_config_dir/pool.d/$app.conf"
    ynh_exec_warn_less ynh_secure_remove --file="$fpm_config_dir/conf.d/20-$app.ini"

    # If the php version used is not the default version for YunoHost
    if [ "$phpversion" != "$YNH_DEFAULT_PHP_VERSION" ]
    then
        # Remove this specific version of php
        ynh_remove_php
    fi
}

# Install another version of php.
#
# [internal]
#
# usage: ynh_install_php --phpversion=phpversion [--package=packages]
# | arg: -v, --phpversion=  - Version of php to install.
# | arg: -p, --package=     - Additionnal php packages to install
#
# Requires YunoHost version 3.8.1 or higher.
ynh_install_php () {
    # Declare an array to define the options of this helper.
    local legacy_args=vp
    local -A args_array=( [v]=phpversion= [p]=package= )
    local phpversion
    local package
    # Manage arguments with getopts
    ynh_handle_getopts_args "$@"
    package=${package:-}

    # Store phpversion into the config of this app
    ynh_app_setting_set $app phpversion $phpversion

    if [ "$phpversion" == "$YNH_DEFAULT_PHP_VERSION" ]
    then
        ynh_die "Do not use ynh_install_php to install php$YNH_DEFAULT_PHP_VERSION"
    fi

    # Create the file if doesn't exist already
    touch /etc/php/ynh_app_version

    # Do not add twice the same line
    if ! grep --quiet "$YNH_APP_INSTANCE_NAME:" "/etc/php/ynh_app_version"
    then
        # Store the ID of this app and the version of php requested for it
        echo "$YNH_APP_INSTANCE_NAME:$phpversion" | tee --append "/etc/php/ynh_app_version"
    fi

    # Add an extra repository for those packages
    ynh_install_extra_repo --repo="https://packages.sury.org/php/ $(ynh_get_debian_release) main" --key="https://packages.sury.org/php/apt.gpg" --priority=995 --name=extra_php_version

    # Install requested dependencies from this extra repository.
    # Install php-fpm first, otherwise php will install apache as a dependency.
    ynh_add_app_dependencies --package="php${phpversion}-fpm"
    ynh_add_app_dependencies --package="php$phpversion php${phpversion}-common $package"

    # Set the default php version back as the default version for php-cli.
    update-alternatives --set php /usr/bin/php$YNH_DEFAULT_PHP_VERSION

    # Pin this extra repository after packages are installed to prevent sury of doing shit
    ynh_pin_repo --package="*" --pin="origin \"packages.sury.org\"" --priority=200 --name=extra_php_version
    ynh_pin_repo --package="php${YNH_DEFAULT_PHP_VERSION}*" --pin="origin \"packages.sury.org\"" --priority=600 --name=extra_php_version --append

    # Advertise service in admin panel
    yunohost service add php${phpversion}-fpm --log "/var/log/php${phpversion}-fpm.log"
}

# Remove the specific version of php used by the app.
#
# [internal]
#
# usage: ynh_install_php
#
# Requires YunoHost version 3.8.1 or higher.
ynh_remove_php () {
    # Get the version of php used by this app
    local phpversion=$(ynh_app_setting_get $app phpversion)

    if [ "$phpversion" == "$YNH_DEFAULT_PHP_VERSION" ] || [ -z "$phpversion" ]
    then
        if [ "$phpversion" == "$YNH_DEFAULT_PHP_VERSION" ]
        then
            ynh_print_err "Do not use ynh_remove_php to remove php$YNH_DEFAULT_PHP_VERSION !"
        fi
        return 0
    fi

    # Create the file if doesn't exist already
    touch /etc/php/ynh_app_version

    # Remove the line for this app
    sed --in-place "/$YNH_APP_INSTANCE_NAME:$phpversion/d" "/etc/php/ynh_app_version"

    # If no other app uses this version of php, remove it.
    if ! grep --quiet "$phpversion" "/etc/php/ynh_app_version"
    then
        # Remove the service from the admin panel
        if ynh_package_is_installed --package="php${phpversion}-fpm"; then
            yunohost service remove php${phpversion}-fpm
        fi

        # Purge php dependencies for this version.
        ynh_package_autopurge "php$phpversion php${phpversion}-fpm php${phpversion}-common"
    fi
}

# Define the values to configure php-fpm
#
# [internal]
#
# usage: ynh_get_scalable_phpfpm --usage=usage --footprint=footprint [--print]
# | arg: -f, --footprint=       - Memory footprint of the service (low/medium/high).
# low    - Less than 20Mb of ram by pool.
# medium - Between 20Mb and 40Mb of ram by pool.
# high   - More than 40Mb of ram by pool.
# Or specify exactly the footprint, the load of the service as Mb by pool instead of having a standard value.
# To have this value, use the following command and stress the service.
# watch -n0.5 ps -o user,cmd,%cpu,rss -u APP
#
# | arg: -u, --usage=           - Expected usage of the service (low/medium/high).
# low    - Personal usage, behind the sso.
# medium - Low usage, few people or/and publicly accessible.
# high   - High usage, frequently visited website.
#
# | arg: -p, --print            - Print the result (intended for debug purpose only when packaging the app)
ynh_get_scalable_phpfpm () {
    local legacy_args=ufp
    # Declare an array to define the options of this helper.
    local -A args_array=( [u]=usage= [f]=footprint= [p]=print )
    local usage
    local footprint
    local print
    # Manage arguments with getopts
    ynh_handle_getopts_args "$@"
    # Set all characters as lowercase
    footprint=${footprint,,}
    usage=${usage,,}
    print=${print:-0}

    if [ "$footprint" = "low" ]
    then
        footprint=20
    elif [ "$footprint" = "medium" ]
    then
        footprint=35
    elif [ "$footprint" = "high" ]
    then
        footprint=50
    fi

    # Define the factor to determine min_spare_servers
    # to avoid having too few children ready to start for heavy apps
    if [ $footprint -le 20 ]
    then
        min_spare_servers_factor=8
    elif [ $footprint -le 35 ]
    then
        min_spare_servers_factor=5
    else
        min_spare_servers_factor=3
    fi

    # Define the way the process manager handle child processes.
    if [ "$usage" = "low" ]
    then
        php_pm=ondemand
    elif [ "$usage" = "medium" ]
    then
        php_pm=dynamic
    elif [ "$usage" = "high" ]
    then
        php_pm=static
    else
        ynh_die --message="Does not recognize '$usage' as an usage value."
    fi

    # Get the total of RAM available, except swap.
    local max_ram=$(ynh_get_ram --total --ignore_swap)

    at_least_one() {
        # Do not allow value below 1
        if [ $1 -le 0 ]
        then
            echo 1
        else
            echo $1
        fi
    }

    # Define pm.max_children
    # The value of pm.max_children is the total amount of ram divide by 2 and divide again by the footprint of a pool for this app.
    # So if php-fpm start the maximum of children, it won't exceed half of the ram.
    php_max_children=$(( $max_ram / 2 / $footprint ))
    # If process manager is set as static, use half less children.
    # Used as static, there's always as many children as the value of pm.max_children
    if [ "$php_pm" = "static" ]
    then
        php_max_children=$(( $php_max_children / 2 ))
    fi
    php_max_children=$(at_least_one $php_max_children)

    # To not overload the proc, limit the number of children to 4 times the number of cores.
    local core_number=$(nproc)
    local max_proc=$(( $core_number * 4 ))
    if [ $php_max_children -gt $max_proc ]
    then
        php_max_children=$max_proc
    fi

    # Get a potential forced value for php_max_children
    local php_forced_max_children=$(ynh_app_setting_get --app=$app --key=php_forced_max_children)
    if [ -n "$php_forced_max_children" ]; then
        php_max_children=$php_forced_max_children
    fi

    if [ "$php_pm" = "dynamic" ]
    then
        # Define pm.start_servers, pm.min_spare_servers and pm.max_spare_servers for a dynamic process manager
        php_min_spare_servers=$(( $php_max_children / $min_spare_servers_factor ))
        php_min_spare_servers=$(at_least_one $php_min_spare_servers)

        php_max_spare_servers=$(( $php_max_children / 2 ))
        php_max_spare_servers=$(at_least_one $php_max_spare_servers)

        php_start_servers=$(( $php_min_spare_servers + ( $php_max_spare_servers - $php_min_spare_servers ) /2 ))
        php_start_servers=$(at_least_one $php_start_servers)
    else
        php_min_spare_servers=0
        php_max_spare_servers=0
        php_start_servers=0
    fi

    if [ $print -eq 1 ]
    then
        ynh_debug --message="Footprint=${footprint}Mb by pool."
        ynh_debug --message="Process manager=$php_pm"
        ynh_debug --message="Max RAM=${max_ram}Mb"
        if [ "$php_pm" != "static" ]
        then
            ynh_debug --message="\nMax estimated footprint=$(( $php_max_children * $footprint ))"
            ynh_debug --message="Min estimated footprint=$(( $php_min_spare_servers * $footprint ))"
        fi
        if [ "$php_pm" = "dynamic" ]
        then
            ynh_debug --message="Estimated average footprint=$(( $php_max_spare_servers * $footprint ))"
        elif [ "$php_pm" = "static" ]
        then
            ynh_debug --message="Estimated footprint=$(( $php_max_children * $footprint ))"
        fi
        ynh_debug --message="\nRaw php-fpm values:"
        ynh_debug --message="pm.max_children = $php_max_children"
        if [ "$php_pm" = "dynamic" ]
        then
            ynh_debug --message="pm.start_servers = $php_start_servers"
            ynh_debug --message="pm.min_spare_servers = $php_min_spare_servers"
            ynh_debug --message="pm.max_spare_servers = $php_max_spare_servers"
        fi
    fi
}
