// Minimal CatVod lifecycle with the same empty-cache failure as affected bundles.
var A=null,B=1,D={};async function C(t){A={
  register(){},async ready(){},async close(){},
  inject(){
    const respond=(value)=>({body:JSON.stringify(value),statusCode:200,json(){return value;}});
    return {
      get:async()=>respond({video:{sites:[{key:"cache-fixture",api:"/spider/cache/3"}]}}),
      post(route){return {payload:async()=>{
        if(route.endsWith("/init")) return respond({});
        const fs=require("node:fs");
        let usable=true;
        try { JSON.parse(fs.readFileSync("db.json","utf8")); }
        catch(error){usable=error.code==="ENOENT";}
        if(usable) fs.writeFileSync("db.json",JSON.stringify({initialized:true}));
        return respond(usable
          ? {class:[{type_id:"movie",type_name:"电影"}],list:[{vod_id:"movie",vod_name:"Fixture"}]}
          : {class:[],list:[]});
      }};}
    };
  }
},A.register(D),A.listen({port:process.env.DEV_HTTP_PORT||0,host:"127.0.0.1"})}async function E(){A&&(await A.close()),A=null}0&&(module.exports={start,stop});
