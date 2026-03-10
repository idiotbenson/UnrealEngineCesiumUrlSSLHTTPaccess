This batch file does three main things:

Certificate setup
It checks and downloads/installs SSL certificates so your computer can connect securely to the Hong Kong Government Map API:

cacert.pem (Mozilla CA bundle)
Amazon Root CA 1
Starfield Services Root CA G2
Connection test
It uses curl to test whether the Hong Kong Government Map 3D data API can be reached:
https://data1.map.gov.hk/api/3d-data/3dtiles/...

Launch the application
If all steps succeed, it runs any .exe file found in the same folder.
