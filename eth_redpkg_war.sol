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

@dev 抢以太币红包

任何人都可以在群中发送红包，但需要设置一个红包口令，只有知道口令的用户参与参与抢红包。
在红包生成成功后，将此红包发送到群中，群友在看到此消息后则可参与抢红包，同一个用户只能抢一次。
红包默认过期时间为1天（可通过合约调整），一天后可取回剩余Token。
当红包已抢结束时，如果还要剩余则奖励给合约创建者。
*/
contract ETHRedPkgWar is DOSOnChainSDK{
    
    address payable public owner ;//合约创建者
    uint16 liveTime = 5760 ;//一天的以太坊区块数量
    enum WarModels { Random,Avg,DOSRandom}
    //当前红包ID
    uint public currRed;

    constructor()public {
        owner = msg.sender;
    }

    /**
     * @dev 出现一个新的抢红包事件
     * @param creater 红包创建者
     * @param id 红包ID
     */
    event NewWar(address indexed creater, uint id);
    /**
     * @dev 新的抢红包结果
     * @dev user: 参战者
     * @dev id: 红包ID
     * @dev value: 本次抢到的量
     * @dev balance: 红包剩余量
     */
    event NewFireResult(address indexed user,uint id,uint value,uint balance);


    // 所有红包
    mapping(uint => Redpkg) allWars;
    // 进行中的战争: （红包ID->余额）
    mapping(uint => uint) public goingWarsBalance;
    uint[] warIds;
    // 用户参与抢红包的历史记录
    mapping(address => uint[])   userJoinedWars;
    // 用户创建的红包记录
    mapping(address => uint[])   userCreateWars;

    //红包基本信息
    struct Redpkg {
        address sender ;//红包发送者
        uint expireTime; //红包过期时间
        uint token ;//总Token
        uint balance; //余额
        WarModels warModel ;//大战模式：0=平方，1=碰运气
        uint16 peopleLimit ;//人数限制
        string remark ;//红包备注
        bytes32 pwd ;//参与抢红包的密码

        address[] joinedUsers;
        mapping(address => uint) joined;//已参与者
    }


    /**
     * @dev 发起新红包
     * @param _warModel 红包类型（Random=0=随机,Avg=1=平均）
     * @param _peopleLimit 人数限制，必须大于0
     * @param _remark 备注
     * @param _pwd 红包口令
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
        //发送事件
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
     * @dev 携带口令 _pwd 抢红包 _id。
     * 如果红包已抢完或者已经抢过则会失败，否则可以抢。
     * 成功抢到红包，将会收到事件。
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
        // 发送事件
        emit NewFireResult(_user,_id,_value,pkg.balance);
        if (pkg.balance==0){
            delete goingWarsBalance[_id];
            return;
        }
        goingWarsBalance[_id] = pkg.balance;
        if (pkg.joinedUsers.length >= pkg.peopleLimit){
            //如果已经结束，则将剩余转移给合约创建者。
            //这里是合约创建的收益来源
            _addJoin(owner, _id,pkg.balance);
        }
    }

    /**
    * @dev  返回 msg.sender 所有创建的 limit 个红包。
    */
    function queryMyCreateds(uint16 _start,uint16 _limit)
        public view returns(uint[] memory ids){
        return _getSlice(userCreateWars[msg.sender],_start,_limit);
    }

    /**
     * @dev 返回 msg.sender 所有参与的 limit 个红包。
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
     * @dev 查询某红包的抢包情况
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
     * 查询进行中的红包
     * TODO: 当合约大量出现时有性能问题
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
     * @dev 返回列表从 start 开始的中 limit 数量元素，limit 为0时则表示无数量限制。
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
     * @dev 生成随机数
    */
    function _random(uint _max) internal view returns (uint8) {
        uint randomnumber = uint(keccak256(
            abi.encodePacked(block.timestamp, msg.sig)
            )) % _max;
        randomnumber = randomnumber + 1;
        return uint8(randomnumber);
    }
  
    //请求信息
    mapping(uint => requestInfo) requiesInfos;
    struct requestInfo{
        uint redpkgID;
        address payable sender;
    }

    // 请求获得随机数
    function requesRandomFire(uint _id) private{
        uint requestId = DOSRandom(1, now);
        // 记录请求信息
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
    // 响应回调
    function __callback__(uint requestId, uint generatedRandom)
            public
            auth(requestId) {
        requestInfo storage info = requiesInfos[requestId];

        //有可能已被抢完
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