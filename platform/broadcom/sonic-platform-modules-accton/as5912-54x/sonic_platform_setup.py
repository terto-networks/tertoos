from setuptools import setup

DEVICE_NAME = 'accton'
HW_SKU = 'x86_64-accton_as5912_54x-r0'

setup(
    name='sonic-platform',
    version='1.0',
    description='SONiC platform API implementation on Accton AS5912-54X',
    license='Apache 2.0',
    author='TertoOS Team',
    author_email='eduardoterto@gmail.com',
    url='https://github.com/terto-networks/tertoos',
    maintainer='TertoOS',
    packages=[
        'sonic_platform',
    ],
    package_dir={
        'sonic_platform': '../../../../device/{}/{}/sonic_platform'.format(DEVICE_NAME, HW_SKU)},
    classifiers=[
        'Development Status :: 3 - Alpha',
        'Environment :: Plugins',
        'Intended Audience :: Developers',
        'Intended Audience :: Information Technology',
        'Intended Audience :: System Administrators',
        'License :: OSI Approved :: Apache Software License',
        'Natural Language :: English',
        'Operating System :: POSIX :: Linux',
        'Programming Language :: Python :: 3.7',
        'Topic :: Utilities',
    ],
    keywords='sonic SONiC platform PLATFORM',
)
