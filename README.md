aws_vpc
=======

My attempts to create an AWS virtual private cloud.

Requirements
------------

- [RVM](https://rvm.io/)
- Invoke the `./go` script.

Usage
-----

    ./go clean        # Remove any temporary products.
    ./go clobber      # Remove any generated file.
    ./go destroy_vpc  # Destroy VPC
    ./go setup_vpc    # Setup VPC

License
-------

These scripts are covered by the [MIT License](http://www.opensource.org/licenses/mit-license).
