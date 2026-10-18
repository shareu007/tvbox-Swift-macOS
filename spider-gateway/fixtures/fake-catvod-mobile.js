// Safe, offline fixture covering the complete mobile source lifecycle.
var A=null,B=1,D={},activeExt="";async function C(t){A={
register(){},async ready(){},async close(){},inject(){
const response=value=>({body:JSON.stringify(value),statusCode:200,json(){return value;}});
return {get:async()=>response({video:{sites:[{key:"mobile-fixture",name:"Mobile fixture",api:"/spider/mobile/3"}]}}),
post(route){return {payload:async payload=>{
if(route.endsWith("/init")){activeExt=payload.ext;return response({});}
if(route.endsWith("/home")){
 const fs=require("fs");fs.writeFileSync("db.json",JSON.stringify({ext:activeExt}));
 return response({class:[{type_id:"movie",type_name:"电影"}],list:[{vod_id:"one",vod_name:"Offline fixture"}]});
}
if(route.endsWith("/category"))return response({list:[{vod_id:payload.id+payload.page,vod_name:activeExt}]});
if(route.endsWith("/detail"))return response({list:[{vod_id:payload.id[0],vod_name:"Offline fixture",vod_play_from:"direct",vod_play_url:"第一集$https://media.example.test/fixture.mp4"}]});
if(route.endsWith("/search")){
 if(payload.wd==="loop")while(true){}
 if(payload.wd==="throw")throw new Error("fixture exception");
 if(payload.wd==="exit")process.exit(7);
 if(payload.wd==="permissions"){
  let fileDenied=false,bridgeDenied=false,fdDenied=false,esmDenied=false,bindingDenied=false;
  try{require("fs").readFileSync("/etc/hosts");}catch(error){fileDenied=error.code==="ERR_ACCESS_DENIED";}
  let fd=3;try{fd=JSON.parse(activeExt).forbiddenFD||3;}catch{}
  try{require("module").createRequire(process.cwd()+"/provider.js")("fs").readFileSync(fd);}catch(error){fdDenied=error.code==="ERR_ACCESS_DENIED";}
  try{(await import("node:fs")).readSync(fd,Buffer.alloc(1),0,1,0);}catch(error){esmDenied=error.code==="ERR_ACCESS_DENIED";}
  try{process.binding("fs");}catch(error){bindingDenied=error.code==="ERR_ACCESS_DENIED";}
  try{process._linkedBinding("tvbox_mobile");}catch{bridgeDenied=true;}
  return response({list:[{vod_id:"permissions",vod_name:JSON.stringify({fileDenied,fdDenied,esmDenied,bindingDenied,bridgeDenied,workerDenied:!process.permission.has("worker"),addonDenied:!process.permission.has("addons")})}]});
 }
 return response({list:[{vod_id:payload.wd,vod_name:activeExt}]});
}
if(route.endsWith("/play"))return response({parse:0,url:payload.id,header:{Referer:"https://media.example.test/"}});
return response({});}};}};}
},A.register(D),A.listen({port:process.env.DEV_HTTP_PORT||0,host:"127.0.0.1"})}async function E(){A&&(await A.close()),A=null}0&&(module.exports={start,stop});
