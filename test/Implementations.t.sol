// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {MarginaliaRouter} from "../src/MarginaliaRouter.sol";
import {MarginaliaJudge} from "../src/MarginaliaJudge.sol";
import {MarginaliaTreasury} from "../src/MarginaliaTreasury.sol";
import {MarginaliaPricer} from "../src/MarginaliaPricer.sol";

contract ImplementationFactory {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") { deployed := create2(0, add(code, 32), mload(code), salt) }
        require(deployed != address(0), "constructor failed");
    }
}

contract ImplementationsTest is Test {
    function testFactoryDeploysAllFourWithoutArgumentsOrExternalDependencies() public {
        vm.chainId(1);
        ImplementationFactory factory = new ImplementationFactory();
        bytes[4] memory creation = [
            type(MarginaliaRouter).creationCode,
            type(MarginaliaJudge).creationCode,
            type(MarginaliaTreasury).creationCode,
            type(MarginaliaPricer).creationCode
        ];
        uint256 deploymentGas;
        for (uint256 i; i < creation.length; ++i) {
            assertLe(creation[i].length, 49_152);
            uint256 beforeGas = gasleft();
            address deployed = factory.deploy(creation[i], bytes32(i));
            deploymentGas += beforeGas - gasleft();
            bytes memory code = deployed.code;
            assertGt(code.length, 0);
            assertLe(code.length, 24_576);
            for (uint256 j; j < code.length; ++j) {
                uint8 op = uint8(code[j]);
                if (op >= 0x60 && op <= 0x7f) {
                    j += op - 0x5f;
                    continue;
                }
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
            }
            if (i < 3) {
                (bool ok, bytes memory result) = deployed.staticcall(abi.encodeWithSignature("hook()"));
                assertTrue(ok);
                assertEq(abi.decode(result, (address)), address(1), "implementation must be locked");
            }
        }
        assertLt(deploymentGas, 16_777_216);
        emit log_named_uint("four implementation CREATE2 deployments (gas)", deploymentGas);
    }

    function testImplementationsRejectInitialization() public {
        MarginaliaRouter r = new MarginaliaRouter();
        MarginaliaJudge j = new MarginaliaJudge();
        MarginaliaTreasury t = new MarginaliaTreasury();
        vm.expectRevert(MarginaliaRouter.AlreadyInitialised.selector);
        r.init(IPoolManager(address(this)), address(this));
        vm.expectRevert(MarginaliaJudge.AlreadyInitialised.selector);
        j.init(address(this), address(this), bytes32("action"), address(this));
        vm.expectRevert(MarginaliaTreasury.AlreadyInitialised.selector);
        t.init(address(this));
    }

    function testClonesInitializeOnceOnlyFromTheirHook() public {
        IPoolManager manager = IPoolManager(address(new PoolManager(address(this))));
        MarginaliaRouter r = MarginaliaRouter(Clones.clone(address(new MarginaliaRouter())));
        MarginaliaJudge j = MarginaliaJudge(Clones.clone(address(new MarginaliaJudge())));
        MarginaliaTreasury t = MarginaliaTreasury(Clones.clone(address(new MarginaliaTreasury())));
        address stranger = makeAddr("stranger");
        vm.startPrank(stranger);
        vm.expectRevert(MarginaliaRouter.OnlyHook.selector);
        r.init(manager, address(this));
        vm.expectRevert(MarginaliaJudge.OnlyHook.selector);
        j.init(address(this), address(this), bytes32("action"), address(this));
        vm.expectRevert(MarginaliaTreasury.OnlyHook.selector);
        t.init(address(this));
        vm.stopPrank();
        r.init(manager, address(this));
        j.init(address(this), address(this), bytes32("action"), address(this));
        t.init(address(this));
        assertEq(address(r.hook()), address(this));
        assertEq(address(j.hook()), address(this));
        assertEq(address(t.hook()), address(this));
        vm.expectRevert(MarginaliaRouter.AlreadyInitialised.selector);
        r.init(manager, address(this));
        vm.expectRevert(MarginaliaJudge.AlreadyInitialised.selector);
        j.init(address(this), address(this), bytes32("action"), address(this));
        vm.expectRevert(MarginaliaTreasury.AlreadyInitialised.selector);
        t.init(address(this));
    }
}
