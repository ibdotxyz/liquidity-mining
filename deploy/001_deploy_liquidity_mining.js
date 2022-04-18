const { ethers } = require('hardhat');

module.exports = async({
    getNamedAccounts,
    deployments,
    getChainId,
    getUnnamedAccounts,
}) => {
    const {deploy, get} = deployments;
    const {deployer, multisig} = await getNamedAccounts();

    const lm = await deploy('LiquidityMining', {
        from: deployer,
        args: [],
        log: true
    });

    const comptroller = (await get('Comptroller')).address;

    const liquidityMiningFactory = await ethers.getContractFactory("LiquidityMining");
    const fragment = liquidityMiningFactory.interface.getFunction('initialize');
    const initData = liquidityMiningFactory.interface.encodeFunctionData(fragment, [multisig, comptroller])

    const proxy = await deploy('LiquidityMiningProxy', {
        from: deployer,
        args: [lm.address, initData],
        log: true
    });

    await deploy('LiquidityMiningLens', {
        from: deployer,
        args: [proxy.address],
        log: true
    })
}
