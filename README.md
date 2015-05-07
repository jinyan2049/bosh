# BOSH [![Build Status](https://travis-ci.org/cloudfoundry/bosh.png?branch=master)](https://travis-ci.org/cloudfoundry/bosh) [![Code Climate](https://codeclimate.com/github/cloudfoundry/bosh.png)](https://codeclimate.com/github/cloudfoundry/bosh)

* Documentation: [docs.cloudfoundry.org/bosh](http://docs.cloudfoundry.org/bosh)
* IRC: `#bosh` on freenode
* Google groups:
  [bosh-users](https://groups.google.com/a/cloudfoundry.org/group/bosh-users/topics) &
  [bosh-dev](https://groups.google.com/a/cloudfoundry.org/group/bosh-dev/topics) &
  [vcap-dev](https://groups.google.com/a/cloudfoundry.org/group/vcap-dev/topics) (for CF)

Cloud Foundry BOSH is an open source tool chain for release engineering,
deployment and lifecycle management of large scale distributed services.


## Install

To install the Azure BOSH CLI:

```
sudo apt-get update
sudo apt-get install git

git clone https://github.com/Azure/bosh.git

cd bosh/deploy_for_azure
./install.sh
```

You can download stemcell for Azure from http://cloudfoundry.blob.core.windows.net/stemcell/stemcell.tgz

To configure Azure, you can reference deploy_for_azure/guide.doc

To deploy MicroBosh, you can reference deploy_for_azure/config/micro_bosh.yml.

To deploy single VM cloud foundry, you can reference deploy_for_azure/config/micro_cf.yml.

## File a bug

Bugs can be filed using Github Issues.


## Contributing

Please read the [contributors' guide](CONTRIBUTING.md)
