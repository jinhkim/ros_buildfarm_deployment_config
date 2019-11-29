#!/bin/bash

set -o errexit

function usage {
  echo -e "USAGE: $(basename $0) [ROLE]\n"
  echo -e "Where ROLE is one of 'master', 'agent' or 'repo' (without quotes).\n"
  echo -e "The role can be omitted if this script has run previously.\n"
  exit 1
}

vercomp () {
    if [[ $1 == $2 ]]
    then
        return 0
    fi
    local IFS=.
    local i ver1=($1) ver2=($2)
    # fill empty fields in ver1 with zeros
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++))
    do
        ver1[i]=0
    done
    for ((i=0; i<${#ver1[@]}; i++))
    do
        if [[ -z ${ver2[i]} ]]
        then
            # fill empty fields in ver2 with zeros
            ver2[i]=0
        fi
        if ((10#${ver1[i]} > 10#${ver2[i]}))
        then
            return 1
        fi
        if ((10#${ver1[i]} < 10#${ver2[i]}))
        then
            return 2
        fi
    done
    return 0
}

testvercomp () {
    vercomp $1 $2
    case $? in
        0) op='=';;
        1) op='>';;
        2) op='<';;
    esac
    if [[ $op != $3 ]]
    then
        echo "FAIL: Expected '$3', Actual '$op', Arg1 '$1', Arg2 '$2'"
    else
        echo "Pass: '$1 $op $2'"
    fi
}

BUILDFARM_DEPLOYMENT_PATH=${HOME}/workspace/buildfarm_deployment
BUILDFARM_DEPLOYMENT_URL=https://github.com/ros-infrastructure/buildfarm_deployment.git
BUILDFARM_DEPLOYMENT_BRANCH=master

script_dir="$(dirname $0)"

if [[ $# -gt 1 ]]; then
  usage
elif [[ $# -eq 1 ]] && [[ $1 != "master" && $1 != "agent" && $1 != "repo" ]]; then
  usage
elif [[ $# -eq 0 ]] && [[ ! -f "${script_dir}/role" ]]; then
  usage
fi


# Check if a role file exists for the current machine.
if [ -f "${script_dir}/role" ]; then
  buildfarm_role=$(cat "${script_dir}/role")
  if [ $1 != $buildfarm_role ]; then
    echo "ERROR: this machine was previously provisioned as ${buildfarm_role}"
    echo "  To change role to $1 please delete the 'role' file and rerun this command."
    exit 1
  fi
else
  buildfarm_role="$1"
  echo $buildfarm_role > "${script_dir}/role"
fi

if [ ! -d ${HOME}/workspace/buildfarm_deployment ]; then
  echo "$BUILDFARM_DEPLOYMENT_PATH did not exist, cloning."
  git clone $BUILDFARM_DEPLOYMENT_URL ${HOME}/workspace/buildfarm_deployment -b $BUILDFARM_DEPLOYMENT_BRANCH
fi

echo "Copying in configuration"
mkdir -p /etc/puppet/hieradata
cp hiera/hiera.yaml /etc/puppet/
cp -r hiera/hieradata/* /etc/puppet/hieradata/

echo "Asserting latest version of $BUILDFARM_DEPLOYMENT_URL as $BUILDFARM_DEPLOYMENT_BRANCH"
cd $BUILDFARM_DEPLOYMENT_PATH && git fetch origin && git reset --hard origin/$BUILDFARM_DEPLOYMENT_BRANCH
echo "Running librarian-puppet"
(cd $BUILDFARM_DEPLOYMENT_PATH/ && librarian-puppet install --verbose)
echo "Running puppet"

INSTALLED_PUPPET_VERSION=$(puppet --version)
DESIRED_MIN_PUPPET_VERSION="5.0.0"
PUPPET_PARSER_OPTION=""

vercomp $INSTALLED_PUPPET_VERSION $DESIRED_MIN_PUPPET_VERSION
case $? in
    0) op='=';;
    1) op='>';;
    2) op='<';;
esac
if [[ $op != '<' ]]
then
    echo "using newer puppet version $1 so ignore '--parser future' option"
    PUPPET_PARSER_OPTION=""
else
    echo "puppet version $1 $op $2, use '--parser future' option"
    PUPPET_PARSER_OPTION="--parser future"
fi
env FACTER_buildfarm_role="$buildfarm_role" puppet apply --verbose \
  $PUPPET_PARSER_OPTION \
  --modulepath="${BUILDFARM_DEPLOYMENT_PATH}/modules" \
  --logdest /var/log/puppet.log \
  -e "include role::buildfarm::${buildfarm_role}" \
  || { r=$?; echo "puppet failed, please check /var/log/puppet.log, the last 10 lines are:"; tail -n 10 /var/log/puppet.log; exit $r; }
