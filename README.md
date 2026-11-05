This are patches which enhance the smoothness of the gaming experience.

Right now there are just patches which address memory stalls at allocation time.


That the patches work as expected:

you need to add:

kernel cmdline parameter:
```
defrag_mode=2
```

sysctl:
```
vm.watermark_scale_factor = 300
vm.watermark_boost_factor = 0
vm.compaction_proactiveness = 80
```
