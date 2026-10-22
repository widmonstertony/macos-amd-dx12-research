#version 450
layout(triangles) in;
layout(triangle_strip,max_vertices=4) out;
layout(location=0) flat in uvec2 info[];
layout(location=0) flat out uvec4 result;
layout(push_constant) uniform Params{uint width;uint firstInstance;}p;
void main(){
 uint x=uint(gl_PrimitiveIDIn),y=info[0].y-p.firstInstance;
 uint h=info[0].x+7u*info[1].x+49u*info[2].x;
 vec2 lo=vec2(2.0*float(x)/float(p.width)-1.0,2.0*float(y)/3.0-1.0);
 vec2 hi=vec2(2.0*float(x+1u)/float(p.width)-1.0,2.0*float(y+1u)/3.0-1.0);
 vec2 v[4]=vec2[4](lo,vec2(hi.x,lo.y),vec2(lo.x,hi.y),hi);
 for(int i=0;i<4;++i){gl_Position=vec4(v[i],.5,1);result=uvec4(h,x+1u,info[0].y+1u,0x531bu);EmitVertex();}EndPrimitive();
}
