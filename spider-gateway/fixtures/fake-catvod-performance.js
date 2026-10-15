// Synthetic mutable provider: responses expose call counts, never real URLs.
var A=null,B=1,D={},calls=0;async function C(t){A={
  register(){},async ready(){},async close(){},
  inject(){const respond=value=>({body:JSON.stringify(value),statusCode:200,json(){return value;}});return {
    get:async()=>respond({video:{sites:[{key:"performance",api:"/spider/performance/3"}]}}),
    post(route){return {payload:async payload=>{
      if(route.endsWith("/init"))return respond({});
      calls++;const generation=calls;
      await new Promise(resolve=>setTimeout(resolve,40));
      return respond({generation,list:[{vod_id:"film",vod_name:"Fixture"}],payload});
    }};}
  };}
},A.register(D),A.listen({port:process.env.DEV_HTTP_PORT||0,host:"127.0.0.1"})}async function E(){A&&(await A.close()),A=null}0&&(module.exports={start,stop});
