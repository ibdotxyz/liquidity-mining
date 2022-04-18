require("dotenv").config();

/**
 * @type import('hardhat/config').HardhatUserConfig
 */
require("@nomiclabs/hardhat-waffle");
require('@nomiclabs/hardhat-ethers');
require('@openzeppelin/hardhat-upgrades');
require("@nomiclabs/hardhat-etherscan");
require('hardhat-deploy');

module.exports = {
  solidity: {
    version: "0.8.2" ,
    settings: {
      optimizer: {
        enabled: true,
        runs: 200
      }
    }
  },
  namedAccounts: {
    deployer: 0,
    multisig: {
      mainnet: '0xA5fC0BbfcD05827ed582869b7254b6f141BA84Eb',
      avalanche: '0xf3472A93B94A17dC20F9Dc9D0D48De42FfbD14f4',
      fantom: '0xA5fC0BbfcD05827ed582869b7254b6f141BA84Eb'
    }
  },
  networks: {
    hardhat: {
        forking: {
          enabled: false,
          url: `https://mainnet.infura.io/v3/${process.env.INFURA_TOKEN}`,
        }
    },
    mainnet: {
      url: `https://mainnet.infura.io/v3/${process.env.INFURA_TOKEN}`,
      accounts: process.env.DEPLOY_PRIVATE_KEY == undefined ? [] : [`0x${process.env.DEPLOY_PRIVATE_KEY}`]
    },
    fantom: {
        url: 'https://rpc.ftm.tools/',
        accounts:
          process.env.DEPLOY_PRIVATE_KEY == undefined ? [] : [`0x${process.env.DEPLOY_PRIVATE_KEY}`]
    },
    avalanche: {
      url: 'https://api.avax.network/ext/bc/C/rpc',
      chainId: 43114,
      accounts: process.env.DEPLOY_PRIVATE_KEY == undefined ? [] : [`0x${process.env.DEPLOY_PRIVATE_KEY}`]
    },
  }
};
