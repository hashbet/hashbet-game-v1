const ethers = require('ethers');  

function HashBetCheck(modulo,SecretText,BlockHash){
    let pack = ethers.utils.solidityPack(['uint','bytes32'],[
        SecretText, 
        BlockHash,  
    ]) 
    let result = ethers.utils.keccak256(pack)  
    let outcome =  (ethers.BigNumber.from(result)).mod(modulo) 
    console.log("outcome = ",outcome.toString())
}

// Modulo is the number of equiprobable outcomes in a game:
//  2 for coin flip
//  6 for dice roll
//  6*6 = 36 for double dice
//  37 for roulette
//  100 for classic dice
let modulo = 2 // flip
// SecretText and BlockHash get by hashbet.com game history
let SecretText = 2569774823 
let BlockHash = "0x4013129b0eea56f1bce5fdfd7fb4276116fce499ad706ce7b566483df053cb11"

HashBetCheck(modulo,SecretText,BlockHash)
