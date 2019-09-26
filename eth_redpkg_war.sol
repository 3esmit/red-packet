pragma solidity ^0.5.0;


contract DOSAddressBridgeInterface {
    function getProxyAddress() public view returns (address);
}

contract DOSProxyInterface {
    // function query(address, uint, string memory, string memory) public returns (uint);
    function requestRandom(address, uint8, uint) public returns (uint);
}
 
contract DOSOnChainSDK {
    // Comment out utils library if you don't need it to save gas. (L4 and L17)
    // using utils for *;

    DOSProxyInterface dosProxy;
    DOSAddressBridgeInterface dosAddrBridge =
        DOSAddressBridgeInterface(0xf0CEFfc4209e38EA3Cd1926DDc2bC641cbFFd1cF);

    modifier resolveAddress {
        dosProxy = DOSProxyInterface(dosAddrBridge.getProxyAddress());
        _;
    }

    function fromDOSProxyContract() internal view returns (address) {
        return dosAddrBridge.getProxyAddress();
    }

    function DOSRandom(uint8 mode, uint seed)
        internal
        resolveAddress
        returns (uint)
    {
        return dosProxy.requestRandom(address(this), mode, seed);
    }
    // @dev: Must override __callback__ to process a corresponding random
    //       number. A user-defined event could be added to notify the Dapp
    //       frontend that a new secure random number is generated.
    // @requestId: A unique requestId returned by DOSRandom() for requester to
    //             differentiate random numbers generated concurrently.
    // @generatedRandom: Generated secure random number for the specific
    //                   requestId.
    function __callback__(uint requestId, uint generatedRandom) external{
        // To be overridden in the caller contract.
    }
}


/**

@dev Grab the Ethereum Red Packet

Anyone can send a red envelope in the group, but need to set a red envelope password, only the user who knows the password participates in the red envelope.
After the red envelope is successfully generated, the red envelope is sent to the group, and the group friends can participate in the red packet after seeing the message, and the same user can only grab once.
The red envelope default expiration time is 1 day (can be adjusted by contract), and the remaining token can be retrieved after one day.
When the red envelope has been robbed, if it still needs to be left, it will be awarded to the contract creator.
*/
contract ETHRedPkgWar is DOSOnChainSDK{
    
    address payable public owner ;//Contract creator
    uint16 liveTime = 5760 ;//The number of Ethereum blocks in a day
    enum WarModels { Random,Avg,DOSRandom}
    //Current red envelope ID
    uint public currRed;

    constructor()public {
        owner = msg.sender;
    }

    /**
     * @dev A new red envelope event
     * @param creater Red envelope creator
     * @param id Red envelope ID
     */
    event NewWar(address indexed creater, uint id);
    /**
     * @dev new red envelope results
     * @dev user: the warrior
     * @dev id: red envelope ID
     * @dev value: The amount of this grab
     * @dev balance: red envelope
     */
    event NewFireResult(address indexed user,uint id,uint value,uint balance);


    // All red envelopes
    mapping(uint => Redpkg) allWars;
    // War in progress: (red envelope ID -> balance)
    mapping(uint => uint) public goingWarsBalance;
    uint[] warIds;
    // User participation in the history of red packets
    mapping(address => uint[])   userJoinedWars;
    // User-created red envelope record
    mapping(address => uint[])   userCreateWars;

    //Red envelope basic information
    struct Redpkg {
        address sender ;//red packet sender
        uint expireTime; //Red envelope expiration time
        uint token ;//total token
        uint balance; //balance
        WarModels warModel ;//Great War mode: 0=square, 1=take luck
        uint16 peopleLimit ;//number of people
        string remark ;// red envelope note
        bytes32 pwd ;// involved in the red envelope password

        address[] joinedUsers;
        mapping(address => uint) joined;// participant
    }


    /**
     * @dev Initiate a new red envelope
     * @param _warModel Red packet type (Random=0=random, Avg=1=average)
     * @param _peopleLimit number limit, must be greater than 0
     * @param _remark Notes
     * @param _pwd red envelope password
     */
    function newWar(WarModels _warModel,
        uint16 _peopleLimit,string memory _remark,
        string memory _pwd)
        public payable{
        require(msg.value>0,"msg.value should be >0");
        require(_peopleLimit>0,"_peopleLimit should be >0");
        address[] memory ids = new address[](0);
        Redpkg memory pkg = Redpkg(
            msg.sender,
            block.number+liveTime,
            msg.value,
            msg.value,
            _warModel,
            _peopleLimit,
            _remark,
            keccak256(abi.encodePacked(_pwd)),
            ids
        );
        currRed++;
        allWars[currRed] = pkg;

        goingWarsBalance[currRed] = msg.value;
        warIds.push(currRed);
        userCreateWars[msg.sender].push(currRed);
        //Send event
        emit NewWar(msg.sender,currRed);
    }

    modifier canFire(uint _id,string memory _pwd){
      Redpkg  storage pkg = allWars[_id];
      require(pkg.token > 0,"Not found by id");
      require(pkg.joined[msg.sender]==0, "You has joined,can not repeat");
      require(pkg.expireTime>block.number,"The war is expired");
      require(pkg.joinedUsers.length<pkg.peopleLimit,"You are late");
      require(pkg.pwd == keccak256(abi.encodePacked(_pwd)),"wrong password");
      _;
    }
    /**
     * @dev Carry the password _pwd to grab the red envelope _id.
     * If the red envelope has been grabbed or has been robbed, it will fail, otherwise you can grab it.
     * Successfully grab the red envelope and receive an event.
     */
    function fire(uint _id,string memory _pwd) public canFire(_id,_pwd){
        require(goingWarsBalance[_id]>0,"The war is over");
        Redpkg  storage pkg = allWars[_id];
        if (pkg.warModel==WarModels.DOSRandom){
            requesRandomFire(_id);
            return;
        }

        uint got = 0;
        if (pkg.warModel==WarModels.Random){ //随机
            uint8 r = _random(50);
            if (r==0){
                r = 1;
            }
            got = pkg.balance*r/100;
        }else if (pkg.warModel==WarModels.Avg){//平分
            got = pkg.token/pkg.peopleLimit;
        }
        _addJoin(msg.sender, _id, got);
    }

    function _addJoin(address payable _user,uint _id,uint _value) internal{
        Redpkg  storage pkg = allWars[_id];
        if (_value>pkg.balance){
            _value = pkg.balance;
        }
        pkg.balance -= _value; //更新剩余量
        uint v = pkg.joined[msg.sender];
        if (v==0){
            pkg.joined[msg.sender] = _value;//记录结果
            pkg.joinedUsers.push(msg.sender);
            userJoinedWars[msg.sender].push(_id);//记录
        }else{
            pkg.joined[msg.sender] = v + _value;
        }

        _user.transfer(_value);
        // Send event
        emit NewFireResult(_user,_id,_value,pkg.balance);
        if (pkg.balance==0){
            delete goingWarsBalance[_id];
            return;
        }
        goingWarsBalance[_id] = pkg.balance;
        if (pkg.joinedUsers.length >= pkg.peopleLimit){
            //If it has ended, the remainder is transferred to the contract creator.
            //This is the source of revenue for contract creation.
            _addJoin(owner, _id,pkg.balance);
        }
    }

    /**
     * @dev returns all the limit red packets created by msg.sender.
     */
    function queryMyCreateds(uint16 _start,uint16 _limit)
        public view returns(uint[] memory ids){
        return _getSlice(userCreateWars[msg.sender],_start,_limit);
    }

    /**
     * @dev Returns msg.sender all participating limit red packets.
     *
     */
    function queryMyJoined(uint16 _start,uint16 _limit)
        public view returns(uint[] memory ids){
        return _getSlice(userJoinedWars[msg.sender],_start,_limit);
    }
    function queryWarInfo(uint _id) public view returns(
        address sender ,//红包发送者
        uint expireTime, //红包过期时间
        uint token ,//总Token
        uint balance, //余额
        WarModels warModel ,//大战模式：0=平方，1=碰运气
        uint16 peopleLimit ,//人数限制
        uint16 joinedCount,//已参与人数
        string memory remark //红包备注
    ) {
        Redpkg  storage pkg = allWars[_id];
        require(pkg.token > 0,"Not found by id");
        return (pkg.sender,pkg.expireTime,pkg.token,
        pkg.balance,pkg.warModel,pkg.peopleLimit,uint16(pkg.joinedUsers.length),pkg.remark);
    }

    /**
     * @dev Query the package status of a red envelope
     */
    function queryWarRecords(uint _id,uint16 _start,uint16 _limit)
        public view returns(uint size,address[] memory joins, uint[] memory values ){
        Redpkg storage pkg = allWars[_id];
        require(pkg.token > 0,"Not found by id");
        size = pkg.joinedUsers.length;
        if (_start >= size){
            return (size,joins,values);
        }

        uint count = uint256(_limit);
        if (count==0 || _start+count > size){
            count = size - _start;
        }
        joins = new address[](count);
        values = new uint[](count);
        for (uint i = 0; i < count; i++){
            joins[i] = pkg.joinedUsers[_start+i];
            values[i] = pkg.joined[joins[i]];
        }
    }


    uint[] tempIds;
    /**
     * Querying the ongoing red envelope
     * TODO: Performance issues when there are a large number of contracts
     */
    function queryGoingWars() public returns(uint[] memory ids){
        if (warIds.length==0){
            return tempIds;
        }
        for (uint i = 0; i < warIds.length; i++){
            uint id = warIds[i];
            uint v = goingWarsBalance[id];
            if (v > 0){
                tempIds.push(id);
            }
        }
        return tempIds;
    }

    /**
     * @dev returns the limit number element from the start of the list. If the limit is 0, there is no limit.
     */
    function _getSlice(uint[] memory joined,uint16 start,uint16 limit)
        internal pure returns(uint[] memory){
        if (joined.length==0){
            return joined;
        }
        require(start<joined.length,"out of limit, start should be < joined");
        uint count = uint256(limit);
        if (count==0 || start+limit>joined.length){
            count = joined.length - start;
        }
        uint[]  memory list = new uint[](count);
        for (uint i = 0; i < limit ; i++){
            list[i] = joined[start+i];
        }
        return list;
    }


    /**
     * @dev Generate random numbers
    */
    function _random(uint _max) internal view returns (uint8) {
        uint randomnumber = uint(keccak256(
            abi.encodePacked(block.timestamp, msg.sig)
            )) % _max;
        randomnumber = randomnumber + 1;
        return uint8(randomnumber);
    }
  
    //Request information
    mapping(uint => requestInfo) requiesInfos;
    struct requestInfo{
        uint redpkgID;
        address payable sender;
    }

    // Request to get a random number
    function requesRandomFire(uint _id) private{
        uint requestId = DOSRandom(1, now);
        // Record request information
        requiesInfos[requestId] = requestInfo(
            {
                redpkgID: _id,
                sender: msg.sender
            }
        );
    }
 
    modifier auth(uint id) {
        require(msg.sender == dosAddrBridge.getProxyAddress(),
                "Unauthenticated response from non-DOS.");
        require(requiesInfos[id].redpkgID>0, "Response with invalid request id!");
        _;
    }
    // Response callback
    function __callback__(uint requestId, uint generatedRandom)
            public
            auth(requestId) {
        requestInfo storage info = requiesInfos[requestId];

        //It may have been robbed
        Redpkg  storage pkg = allWars[info.redpkgID];
        if (pkg.balance == 0){
            delete  requiesInfos[requestId];
            return;
        }
        uint r = generatedRandom;
        if (r != 0){
            r = generatedRandom % 50;
        }
        if (r == 0){
            r = 1;
        }
        _addJoin(info.sender, info.redpkgID, pkg.balance*r/100);
        delete  requiesInfos[requestId];
    }

}
