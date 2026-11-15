// Exercise the actual shipped browser script without a network or DOM dependency.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const source = fs.readFileSync(__dirname + '/guest_web/guest.js', 'utf8');
const base = {portion:{title:'Dinner <script>',name:'Alex',foodCents:1001,taxCents:80,feeCents:11,tipCents:200}, approvedTipCents:null,expired:false,closed:false};
async function page(record = base, failed = false, blockedStorage = false) {
  const nodes = new Map();
  const node = id => {
    if (!nodes.has(id)) nodes.set(id, {value:'',textContent:'',hidden:false,disabled:false,events:{}, addEventListener(event, callback){this.events[event]=callback},setAttribute(){},focus(){this.focused=true}});
    return nodes.get(id);
  };
  const buttons = [0,15,20,25].map(percent => ({...node('button'+percent),dataset:{tip:String(percent)}}));
  const requests = [];
  let cleaned = false;
  vm.runInNewContext(source, {
    document:{getElementById:node,querySelectorAll:()=>buttons},
    location:{hash:'#portion-token'},history:{replaceState(){cleaned=true}},
    sessionStorage:{setItem(){if(blockedStorage)throw Error('blocked')},getItem(){return null}},
    Intl, console,
    fetch:async (url, options)=> {
      requests.push({url,options});
      if(failed)throw Error('offline');
      return {ok:true,json:async()=>options.method==='POST'?{...record,approvedTipCents:JSON.parse(options.body).tipCents}:record};
    }
  });
  await new Promise(resolve=>setImmediate(resolve));
  return {node,buttons,requests,cleaned};
}
test('mobile page displays exact cents, treats names as text and removes URL fragment', async()=>{
  const p = await page();
  assert.equal(p.node('total').textContent, '$12.92');
  assert.equal(p.node('bill-title').textContent,'Dinner <script>');
  assert.equal(p.node('portion').hidden,false);
  assert.equal(p.cleaned,true);
  assert.equal(p.requests[0].url,'/guest-api/portion');
  assert.equal(p.requests[0].options.headers.Authorization,'Guest portion-token');
});
test('tip presets use half-up rounding and submit only integer tip cents', async()=>{
  const p = await page();
  p.buttons[3].events.click();
  assert.equal(p.node('tip').value,'2.50');
  p.node('tip').value='3.33';p.node('tip').events.input();
  assert.equal(p.node('total').textContent,'$14.25');
  await p.node('approval').events.submit({preventDefault(){}});
  assert.deepEqual(JSON.parse(p.requests[1].options.body),{tipCents:333});
  assert.equal(p.node('approval').hidden,true);
  assert.match(p.node('status').textContent,/approval is saved/);
});
test('invalid tips never enable approval',async()=>{
  const p=await page();
  for(const value of ['-1','1.001','1e2','100','', 'NaN']) {
    p.node('tip').value=value;p.node('tip').events.input();
    assert.equal(p.node('approve').disabled,true,value);
  }
});
test('approved, expired and closed links do not show an approval form',async()=>{
  for(const record of [{...base,approvedTipCents:333},{...base,expired:true},{...base,closed:true}]) {
    const p=await page(record);assert.equal(p.node('approval').hidden,true);
    assert.ok(p.node('status').textContent.length>0);
  }
});
test('network errors offer a retry and blocked storage still permits access',async()=>{
  const p=await page(base,true);assert.equal(p.node('error').hidden,false);assert.equal(p.node('retry').hidden,false);
  const restricted=await page(base,false,true);assert.equal(restricted.node('portion').hidden,false);
});
